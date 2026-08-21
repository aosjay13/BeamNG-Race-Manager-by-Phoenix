-- Headless test for DISPLAY NAMES ON BEAMMP NAMETAGS in
-- lua/ge/extensions/raceManager.lua.
--
-- Its own file because it is the only suite that cares what the mod says to
-- BeamMP's nametag API, and the whole point of the feature is how LITTLE it
-- says. BeamMP renders nametags itself and players are attached to that
-- rendering -- the distance fade, the hide-behind-objects setting, the
-- spectator list, the colours. There is a way to take the whole thing over
-- (hideNicknames + draw your own, which is what BeamJoy does) and it is
-- deliberately not taken: owning the render means owning every setting a player
-- has already chosen. So this appends text through BeamMP's own
-- setPlayerNickSuffix and touches nothing else, and these checks are what stop
-- that promise quietly widening later.
--
-- Run from the repo root: lua5.3 tests/nametag_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- Every setPlayerNickSuffix the mod makes, in order.
local suffixCalls = {}
-- ...and every OTHER MPVehicleGE call, so a future change that starts reaching
-- for the rendering itself is caught here rather than on a race night.
local otherCalls = {}

local handlers = {}
local OWN_ID = 7

local function makeVehicle(id)
  local v = { id = id }
  function v:getID() return self.id end
  function v:getPosition() return { x = 0, y = 0, z = 0 } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation() end
  function v:queueLuaCommand() end
  function v:setMeshAlpha() end
  return v
end

local world = { [OWN_ID] = makeVehicle(OWN_ID) }
local attached = world[OWN_ID]

getPlayerVehicle = function () return attached end
be = { getPlayerVehicle = function () return attached end }
function be:enterVehicle(_, veh) attached = veh end
getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end
getObjectByID = function (id) return world[id] end

-- The API under test, plus enough of the rest of MPVehicleGE for the extension
-- to load. Anything the mod calls that is NOT the suffix setter is recorded as
-- a violation of the "text and nothing else" rule.
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function () return {} end,
  setPlayerNickSuffix = function (targetName, tagSource, text)
    suffixCalls[#suffixCalls + 1] =
      { name = targetName, source = tagSource, text = text, type = type(text) }
  end,
  setPlayerNickPrefix = function (...)
    otherCalls[#otherCalls + 1] = { fn = 'setPlayerNickPrefix', n = select('#', ...) }
  end,
  hideNicknames = function (...)
    otherCalls[#otherCalls + 1] = { fn = 'hideNicknames', n = select('#', ...) }
  end,
  getPlayers = function ()
    otherCalls[#otherCalls + 1] = { fn = 'getPlayers' }
    return {}
  end,
}

core_vehicles = { removeCurrent = function () return true end,
                  spawnNewVehicle = function () return nil end }
local freeCam = false
commands = {
  setFreeCamera = function () freeCam = true end,
  isFreeCamera  = function () return freeCam end,
  setGameCamera = function () freeCam = false end,
}
core_camera = { setByName = function () end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicleBridge = { executeAction = function () end }
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function () end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- Every broadcast from the current plugin is protocol-stamped; an unstamped one
-- is dropped as coming from an outdated server copy.
local function serverState(t)
  t.rmProtocol = 2
  handlers['RM_Update'](t)
end
local function lastSuffixFor(name)
  local found = nil
  for _, c in ipairs(suffixCalls) do
    if c.name == name then found = c end
  end
  return found
end

local ALICE = { id = 1, name = 'Guest_1111', alias = 'Kestrel',   status = 'waiting' }
local BOB   = { id = 2, name = 'Guest_2222', alias = nil,         status = 'waiting' }
local CARA  = { id = 3, name = 'Guest_3333', alias = 'M. Okafor', status = 'waiting' }

-- ---------------------------------------------------------------------------
-- Off is off
-- ---------------------------------------------------------------------------
-- The rule is server-owned and defaults off, so a league that has assigned no
-- names -- or one already running a nametag mod of its own -- gets nothing it
-- did not ask for.
serverState({ phase = 'waiting', nametags = false, drivers = { ALICE, BOB, CARA } })
check(#suffixCalls == 0, 'nothing is written to a nametag while the rule is off')

-- ---------------------------------------------------------------------------
-- On: a suffix, under our own source key, for the drivers who have a name
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', nametags = true, drivers = { ALICE, BOB, CARA } })
check(#suffixCalls == 2,
  'one suffix per ALIASED driver and no others (got ' .. #suffixCalls .. ')')
local a = lastSuffixFor('Guest_1111')
check(a ~= nil, 'the aliased driver got a suffix')
check(a ~= nil and a.name == 'Guest_1111',
  'keyed by the BeamMP GUEST name, which is what the API matches on')
check(a ~= nil and a.source == 'raceManager',
  'filed under our own tag source, so another mod holding a tag on the same '
    .. 'driver is not overwritten -- suffixes are a map keyed by source')
check(a ~= nil and a.text == ' (Kestrel)', 'and the text is the display name')
check(lastSuffixFor('Guest_2222') == nil,
  'a driver with no display name is left completely alone')

-- ---------------------------------------------------------------------------
-- NOTHING BUT TEXT
-- ---------------------------------------------------------------------------
-- The rule the whole feature is built around. hideNicknames would hand us the
-- render -- and with it the fade, the occlusion and every nametag setting the
-- player has chosen. Writing getPlayers()[pid].name would replace the guest
-- number outright and break BeamMP's own onPlayerLeft cleanup, which matches on
-- that field.
check(#otherCalls == 0,
  'the mod calls NOTHING on MPVehicleGE but the suffix setter (got '
    .. #otherCalls .. ': ' .. (otherCalls[1] and otherCalls[1].fn or '') .. ')')

-- ---------------------------------------------------------------------------
-- An unchanged broadcast is not re-applied
-- ---------------------------------------------------------------------------
-- The state broadcast lands three times a second and the setter is a linear
-- search through BeamMP's player list per call. Re-applying an unchanged set
-- would be a scan per driver per broadcast for the length of a race, to write
-- values that are already there.
local before = #suffixCalls
serverState({ phase = 'racing', nametags = true, drivers = { ALICE, BOB, CARA } })
serverState({ phase = 'racing', nametags = true, drivers = { ALICE, BOB, CARA } })
check(#suffixCalls == before,
  'an unchanged alias set costs nothing (got ' .. (#suffixCalls - before)
    .. ' extra calls across two broadcasts)')

-- ...but a change lands.
serverState({ phase = 'racing', nametags = true, drivers = {
  { id = 1, name = 'Guest_1111', alias = 'Kestrel' },
  { id = 2, name = 'Guest_2222', alias = 'RedFive' },
  CARA } })
local b = lastSuffixFor('Guest_2222')
check(b ~= nil and b.text == ' (RedFive)', 'a newly named driver is picked up')

-- ---------------------------------------------------------------------------
-- CLEARING PASSES AN EMPTY STRING, NEVER nil
-- ---------------------------------------------------------------------------
-- This is a live trap, not a style rule. BeamMP's setter opens with
--
--   if text == nil then text = tagSource; tagSource = 'default' end
--
-- so clearing with nil does not clear anything: it shifts the arguments and
-- writes the literal word `raceManager` onto that driver's nametag, filed under
-- a source we can no longer reach to remove it.
serverState({ phase = 'racing', nametags = true, drivers = {
  { id = 1, name = 'Guest_1111', alias = 'Kestrel' },
  { id = 2, name = 'Guest_2222', alias = nil },
  CARA } })
local cleared = lastSuffixFor('Guest_2222')
check(cleared ~= nil and cleared.text == '',
  'an alias taken away clears the suffix')
check(cleared ~= nil and cleared.type == 'string',
  'and clears it with a STRING -- a nil text would shift the arguments and put '
    .. 'the word "raceManager" on the nametag instead')
for _, c in ipairs(suffixCalls) do
  check(c.type == 'string', 'every call passed a string text, never nil')
  check(c.source == 'raceManager', 'and every call used our own tag source')
end

-- ---------------------------------------------------------------------------
-- Switching the rule off takes every suffix back
-- ---------------------------------------------------------------------------
suffixCalls = {}
serverState({ phase = 'racing', nametags = false, drivers = { ALICE, BOB, CARA } })
check(#suffixCalls >= 2, 'turning the rule off clears what it put on')
for _, c in ipairs(suffixCalls) do
  check(c.text == '', 'and clears it rather than rewriting it')
end
-- ...and having cleared, it stays quiet.
suffixCalls = {}
serverState({ phase = 'racing', nametags = false, drivers = { ALICE, BOB, CARA } })
check(#suffixCalls == 0, 'with the rule off there is nothing left to clear')

-- ---------------------------------------------------------------------------
-- Leaving the server takes them off too
-- ---------------------------------------------------------------------------
-- A tag left behind by a mod that is no longer running is somebody else's bug
-- report, and the session ending is the last moment the mod can still reach
-- BeamMP's player list to take it back off.
serverState({ phase = 'racing', nametags = true, drivers = { ALICE, CARA } })
suffixCalls = {}
RM.onServerLeave()
check(#suffixCalls >= 2, 'leaving the session removes every suffix this mod set')
for _, c in ipairs(suffixCalls) do
  check(c.text == '', 'each one cleared with an empty string')
end

if fails == 0 then
  print(('nametag_test: %d checks, 0 failures'):format(checks))
else
  print(('nametag_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
