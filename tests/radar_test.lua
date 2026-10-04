-- Headless test for THE RADAR in lua/ge/extensions/raceManager/radar.lua.
--
-- The Radar app draws the cars around this driver's own car and is told them on
-- RaceManagerRadar. What is pinned here: alone, nothing is sent; with a car in
-- range, each car arrives in OUR car's frame with its outline-to-outline gap;
-- the last car leaving sends one empty push and then silence; and the race
-- information (position, a lap up or down) appears only in a race.
--
-- Run from the repo root: lua5.3 tests/radar_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol) return type(a) == 'number' and math.abs(a - b) <= (tol or 0.05) end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local hooks, handlers = {}, {}
local vehicles, byId = {}, {}

local function car(id, x, y, hx, hy, opts)
  opts = opts or {}
  local v = { id = id, x = x, y = y, z = 0, hx = hx or 0, hy = hy or 1,
              len = opts.len or 4.5, wid = opts.wid or 1.9,
              model = opts.model or 'etk800', hidden = opts.hidden }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
  function v:getDirectionVectorUp() return { x = 0, y = 0, z = 1 } end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
  function v:getJBeamFilename() return self.model end
  function v:getInitialLength() return self.len end
  function v:getInitialWidth() return self.wid end
  function v:getInitialHeight() return 1.4 end
  function v:isHidden() return self.hidden == true end
  function v:setPositionRotation(px, py, pz) self.x, self.y, self.z = px, py, pz end
  function v:queueLuaCommand() end
  function v:setMeshAlpha() end
  vehicles[#vehicles + 1] = v
  byId[id] = v
  return v
end
local function remove(v)
  for i, o in ipairs(vehicles) do if o == v then table.remove(vehicles, i) break end end
  byId[v.id] = nil
end

local me = car(7, 0, 0, 0, 1)

be               = { getPlayerVehicle = function () return me end }
getPlayerVehicle = function () return me end
getAllVehicles   = function () return vehicles end
getObjectByID    = function (id) return byId[id] end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

-- Vehicle 8 is player 2's car. No isOwn: every car counts as "ours" for the
-- ownership questions, which is the singleplayer path, and the radar skips only
-- the car being driven.
local mpVehicles = {}
MPVehicleGE = { getVehicles = function () return mpVehicles end }
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
local radar = require('raceManager/radar')

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function pushes()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerRadar' then out[#out + 1] = h.payload end
  end
  return out
end
local function last() local p = pushes(); return p[#p] end
local function frames(n, dt) for _ = 1, n do RM.onUpdate(dt or 0.05) end end
local function reset() hooks = {} end
local function carIn(p, i) return p and p.cars and p.cars[i or 1] end

-- ---------------------------------------------------------------------------
-- Alone: nothing at all
-- ---------------------------------------------------------------------------
reset()
frames(40)
check(#pushes() == 0, 'alone, the radar sends nothing')

-- ---------------------------------------------------------------------------
-- A car ahead, in our frame, with its gap
-- ---------------------------------------------------------------------------
local other = car(8, 0, 10, 0, 1)
reset()
frames(10)
local c = carIn(last())
check(c ~= nil, 'a car in range is sent')
check(c and near(c.x, 0) and near(c.y, 10), 'ten meters straight ahead is (0, 10)')
check(c and near(c.a, 0), 'facing the same way is angle 0')
check(c and near(c.g, 5.5), 'the gap is outline to outline: 10 m less two half lengths (got '
  .. tostring(c and c.g) .. ')')
check(last().range == 25, 'with the range the app draws to')
check(last().me and near(last().me.l, 4.5) and near(last().me.w, 1.9), 'and our own car size')

-- Twenty a second while anything is near, not one a frame.
reset()
frames(200, 0.01)       -- two seconds at 100 fps
check(#pushes() >= 38 and #pushes() <= 42, 'about twenty pushes a second at 100 fps (got '
  .. #pushes() .. ' in two seconds)')

-- Alongside on the left.
other.x, other.y = -3, 0
frames(3)
c = carIn(last())
check(c and near(c.x, -3) and near(c.y, 0), 'alongside on the left is x = -3')
check(c and near(c.g, 1.1), 'and the gap is the space between the doors: 3 m less two half widths (got '
  .. tostring(c and c.g) .. ')')

-- ---------------------------------------------------------------------------
-- The frame turns with our car
-- ---------------------------------------------------------------------------
me.hx, me.hy = 1, 0            -- we face +X now
other.x, other.y, other.hx, other.hy = 0, 10, 0, 1
frames(3)
c = carIn(last())
check(c and near(c.x, -10) and near(c.y, 0), 'a car north of us while we face east is on our left (got '
  .. tostring(c and c.x) .. ', ' .. tostring(c and c.y) .. ')')
check(c and near(c.a, -90), 'and facing north it points to our left, -90 degrees (got '
  .. tostring(c and c.a) .. ')')
me.hx, me.hy = 0, 1

-- ---------------------------------------------------------------------------
-- The last car leaving: one empty push, then silence
-- ---------------------------------------------------------------------------
other.x, other.y = 0, 40
reset()
frames(10)
check(#pushes() == 1 and #last().cars == 0, 'the last car leaving sends one empty push (got '
  .. #pushes() .. ')')
reset()
frames(40)
check(#pushes() == 0, 'and then nothing')

-- At the edge of range the car is still sent, for the app to fade it in.
other.x, other.y = 0, 29
frames(10)
check(carIn(last()) ~= nil, 'a car just past 25 m is sent so the app can fade it in')

-- ---------------------------------------------------------------------------
-- What is not a car
-- ---------------------------------------------------------------------------
other.x, other.y = 0, 40
frames(10)                      -- the all-clear push for the car that left
local walker = car(9, 2, 2, 0, 1, { model = 'unicycle' })
local hiddenCar = car(10, -2, 2, 0, 1, { hidden = true })
reset()
frames(20)
check(#pushes() == 0, 'a walking character and a hidden car are not on the radar')
remove(walker); remove(hiddenCar)

-- ---------------------------------------------------------------------------
-- A ghost is marked
-- ---------------------------------------------------------------------------
mpVehicles = { [1] = { gameVehicleID = 8, ownerID = 2 } }
other.x, other.y = 4, 0
handlers['RM_Ghost']({ pid = 2, startedAt = 0, duration = 30 })
frames(10)
c = carIn(last())
check(c and c.gh == true, 'a ghosted car is marked, so the app draws it hollow')
handlers['RM_Ghost']({ pid = 2, active = false })
frames(10)

-- ---------------------------------------------------------------------------
-- Race information, in a race only
-- ---------------------------------------------------------------------------
handlers['RM_ApplyLayout']({
  name = 'oval', width = 20, height = 6,
  checkpoints = {
    { x = 0, y = 100, z = 0, hx = 0, hy = 1 }, { x = 100, y = 100, z = 0, hx = 1, hy = 0 },
    { x = 100, y = 0, z = 0, hx = 0, hy = -1 }, { x = 0, y = 0, z = 0, hx = -1, hy = 0 },
  },
})
local function rows(myLap, myCp, theirLap, theirCp)
  return {
    { id = 1, name = 'Me',  status = 'racing', position = 2, currentLap = myLap, cpCleared = myCp },
    { id = 2, name = 'You', status = 'racing', position = 1, currentLap = theirLap, cpCleared = theirCp },
  }
end
handlers['RM_Update']({ rmProtocol = 2, phase = 'racing', sessionKind = 'race', totalLaps = 9,
  maxResets = -1, drivers = rows(3, 1, 3, 2) })
frames(10)
c = carIn(last())
check(c and c.p == 1, 'in a race the car carries its position (got ' .. tostring(c and c.p) .. ')')
check(c and c.lap == nil, 'and on the same lap, no lap mark')

handlers['RM_Update']({ rmProtocol = 2, phase = 'racing', sessionKind = 'race', totalLaps = 9,
  maxResets = -1, drivers = rows(3, 1, 4, 1) })
frames(10)
c = carIn(last())
check(c and c.lap == 1, 'a car a lap up beside us is marked +1 (got ' .. tostring(c and c.lap) .. ')')

-- Across the line together is the same lap, not a lap apart.
handlers['RM_Update']({ rmProtocol = 2, phase = 'racing', sessionKind = 'race', totalLaps = 9,
  maxResets = -1, drivers = rows(3, 3, 4, 0) })
frames(10)
c = carIn(last())
check(c and c.lap == nil, 'a car just across the line ahead of us is on our lap')

handlers['RM_Update']({ rmProtocol = 2, phase = 'qualifying', sessionKind = 'quali', totalLaps = 9,
  maxResets = -1, drivers = rows(3, 1, 4, 1) })
frames(10)
c = carIn(last())
check(c and c.p == nil and c.lap == nil, 'qualifying shows no positions: best laps are not who you race')

-- ---------------------------------------------------------------------------
-- Spectating: nothing around a car that has been taken
-- ---------------------------------------------------------------------------
handlers['RM_Update']({ rmProtocol = 2, phase = 'racing', sessionKind = 'race', totalLaps = 9,
  maxResets = -1, drivers = rows(3, 1, 3, 2) })
handlers['RM_ForceSpectate']({ reason = 'test', source = 'race' })
reset()
frames(20)
check(#pushes() <= 1 and (#pushes() == 0 or #last().cars == 0),
  'a driver put out to spectate gets an empty radar')
handlers['RM_ReleaseSpectate']({ source = 'race' })

-- ---------------------------------------------------------------------------
-- The gap itself
-- ---------------------------------------------------------------------------
check(near(radar.radarGap(0, 0, 0, 4, 2, 2, 0, 0, 4, 2), 0), 'cars door to door touch: gap 0')
check(near(radar.radarGap(0, 0, 0, 4, 2, 1, 1, 0, 4, 2), 0), 'overlapping cars: gap 0')
check(near(radar.radarGap(0, 0, 0, 4, 2, 0, 6, 0, 4, 2), 2), 'nose to tail 6 m apart: gap 2')
-- A car crossways in front: its side is 3 m past our nose.
check(near(radar.radarGap(0, 0, 0, 4, 2, 0, 6, 90, 4, 2), 3), 'T-bone ahead: gap 3 (got '
  .. radar.radarGap(0, 0, 0, 4, 2, 0, 6, 90, 4, 2) .. ')')
-- Corner to corner on the diagonal.
check(near(radar.radarGap(0, 0, 0, 2, 2, 3, 3, 0, 2, 2), math.sqrt(2)),
  'corner to corner diagonally: the distance between the corners')

if fails == 0 then
  print(string.format('radar_test: %d checks, 0 failures', checks))
else
  print(string.format('radar_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
