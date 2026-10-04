-- Headless test for THE LIGHTS in lua/ge/extensions/raceManager/lights.lua.
--
-- The Lights app draws one light and is told it on RaceManagerLights. What is
-- pinned here is which light, when, and that it is pushed only when it moves:
-- the app is meant to cost nothing, and a push per broadcast would be three a
-- second for a light that changes a few times a race.
--
-- The sounds ride the same transitions, so they are checked beside them.
--
-- Run from the repo root: lua5.3 tests/lights_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local hooks    = {}
local handlers = {}
local sounds   = {}

local veh = { id = 7, x = 0, y = 0, z = 0, hx = 0, hy = 1 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
Engine = { Audio = { playOnce = function (channel, event)
  sounds[#sounds + 1] = { channel = channel, event = event }
end } }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
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
local function lightPushes()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerLights' then out[#out + 1] = h.payload end
  end
  return out
end
local function lastLight()
  local p = lightPushes()
  return p[#p]
end
local function reset() hooks = {}; sounds = {} end
local function lastSound() return sounds[#sounds] and sounds[#sounds].event end

local base = { totalLaps = 5, maxResets = -1, drivers = {}, sessionKind = 'race' }
local function serverState(t)
  local s = { rmProtocol = 2 }
  for k, v in pairs(base) do s[k] = v end
  for k, v in pairs(t) do s[k] = v end
  handlers['RM_Update'](s)
end
local function countdown(n) handlers['RM_Countdown']({ count = n }) end

-- ---------------------------------------------------------------------------
-- The countdown: red builds in, GO is green
-- ---------------------------------------------------------------------------
serverState({ phase = 'grid' })
check(lastLight() and lastLight().light == 'grid', 'the grid shows the gantry, unlit')

reset()
serverState({ phase = 'countdown' })
check(#lightPushes() == 0, 'grid to countdown is the same light, so nothing is pushed')

for _, n in ipairs({ 3, 2, 1 }) do
  reset()
  countdown(n)
  check(lastLight() and lastLight().light == 'count' .. n, 'count ' .. n .. ' is its own light')
  check(lastSound() == 'event:UI_Countdown1', 'and beeps (' .. n .. ')')
end
reset()
countdown(0)
check(lastLight() and lastLight().moment == 'go', 'GO is a moment')
check(lastLight() and lastLight().hold == 3, 'held for three seconds by the app')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')

reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().light == 'off' and lastLight().moment == nil,
  'racing under green after GO is dark, with no second green')
reset()
serverState({ phase = 'racing', flag = 'green' })
serverState({ phase = 'racing', flag = 'green' })
check(#lightPushes() == 0, 'repeated broadcasts of the same state push nothing')
check(#sounds == 0, 'and play nothing')

-- ---------------------------------------------------------------------------
-- Behind the pace car GO is not a green
-- ---------------------------------------------------------------------------
serverState({ phase = 'finished' })
serverState({ phase = 'countdown', paceLap = true })
countdown(3); countdown(2); countdown(1)
reset()
countdown(0)
check(lastLight() and lastLight().moment == nil,
  'a pace-lap start has no GO moment: the formation lap is not racing')
check(lastSound() == 'event:UI_Countdown1', 'just a beep for the release')

reset()
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true })
check(lastLight() and lastLight().light == 'pace', 'the pace lap has its own light')

-- THE DERBY'S GO IS ALWAYS A GREEN, whatever the race's pace-lap rule says.
serverState({ phase = 'waiting', paceLap = true })
handlers['RM_DerbyCountdown']({ count = 1 })
check(lastLight() and lastLight().light == 'count1', 'the derby countdown lights the gantry')
reset()
handlers['RM_DerbyCountdown']({ count = 0 })
check(lastLight() and lastLight().moment == 'go', 'and its GO is green with a pace lap armed for races')
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true })

-- ---------------------------------------------------------------------------
-- GET READY, then the green
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true, greenReady = true })
check(lastLight() and lastLight().light == 'ready', 'GET READY is its own light')
check(lastSound() == 'event:UI_Countdown1', 'and it beeps: eyes stay on the road')

reset()
serverState({ phase = 'racing', flag = 'green', paceLap = true })
check(lastLight() and lastLight().light == 'off', 'the green leaves nothing standing')
check(lastLight() and lastLight().moment == 'green', 'but flashes the green as a moment')
check(lastLight() and lastLight().hold == 4, 'for four seconds')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')

-- ---------------------------------------------------------------------------
-- The caution and the restart
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'yellow', cautionPending = true })
check(lastLight() and lastLight().light == 'cautionBack', 'a caution called: race back to the line')
serverState({ phase = 'racing', flag = 'yellow', caution = true })
check(lastLight() and lastLight().light == 'caution', 'then the frozen caution')
serverState({ phase = 'racing', flag = 'yellow', caution = true, restartPending = true })
check(lastLight() and lastLight().light == 'restart', 'then the restart this lap')
reset()
serverState({ phase = 'racing', flag = 'yellow', caution = true, restartPending = true,
  greenReady = true })
check(lastLight() and lastLight().light == 'ready', 'GET READY on the run in beats the caution')
reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().moment == 'green', 'and the restart is a green flag')

-- ---------------------------------------------------------------------------
-- The red flag beats everything, and lifting it is a green
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'red', caution = true })
check(lastLight() and lastLight().light == 'red', 'a red flag is red, caution or not')
check(lastSound() == 'event:>UI>Main>Cancel', 'with a stop tone')
reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().moment == 'green', 'lifting the red is a green flag')

-- A session ending from under a held light is not a green.
serverState({ phase = 'racing', flag = 'yellow', pacing = true })
reset()
serverState({ phase = 'finished', flag = 'green' })
check(lastLight() and lastLight().light == 'off' and lastLight().moment == nil,
  'a session ended during the pace lap shows no green')
check(#sounds == 0, 'and plays nothing')

-- ---------------------------------------------------------------------------
-- This driver's own flags
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', flag = 'green', drivers = { { id = 1, name = 'Me' } } })
reset()
serverState({ phase = 'racing', flag = 'green', drivers = { { id = 1, name = 'Me', blue = true } } })
check(lastLight() and lastLight().moment == 'blue', 'the blue flag reaches the lights')
reset()
RM.lightsMoment('white')
check(lastLight() and lastLight().moment == 'white' and lastLight().hold == 4,
  'the white flag is a four second moment')
reset()
RM.lightsMoment('nonsense')
check(#lightPushes() == 0, 'an unknown moment pushes nothing')

-- ---------------------------------------------------------------------------
-- The drag tree
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', drivers = {} })
reset()
RM.lightsTree({ stage = 'staged', lane = 2, dial = 9.8, prestaged = true, staged = false })
check(lastLight() and lastLight().light == 'tree', 'a lit tree takes the lights over')
check(lastLight() and lastLight().tree.lane == 2, 'and carries the lane')
check(#sounds == 0, 'staging is silent')
for _, st in ipairs({ 'amber1', 'amber2', 'amber3' }) do
  reset()
  RM.lightsTree({ stage = st, lane = 2, prestaged = true, staged = true })
  check(lastLight() and lastLight().tree.stage == st, st .. ' is pushed')
  check(lastSound() == 'event:UI_Countdown1', st .. ' beeps')
end
reset()
RM.lightsTree({ stage = 'green', lane = 2 })
check(lastSound() == 'event:UI_CountdownGo', 'the green bulb has the start tone')
reset()
RM.lightsTree({ stage = 'off' })
check(lastLight() and lastLight().light == 'off' and lastLight().tree == nil,
  'the tree going out gives the lights back')

-- ---------------------------------------------------------------------------
-- Sound off, and a resend
-- ---------------------------------------------------------------------------
RM.lightsSetSound(false)
reset()
serverState({ phase = 'countdown' })
countdown(3); countdown(0)
check(#sounds == 0, 'with sound off nothing plays')
check(lastLight() and lastLight().moment == 'go', 'and the lights still work')
RM.lightsSetSound(true)

reset()
RM.lightsResend()
check(#lightPushes() == 1 and lastLight().moment == nil,
  'a resend sends the standing light without replaying a moment')

if fails == 0 then
  print(string.format('lights_test: %d checks, 0 failures', checks))
else
  print(string.format('lights_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
