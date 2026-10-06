-- Headless test for PRACTICE GHOSTS in lua/ge/extensions/raceManager.lua.
--
-- A driver practising between sessions used to be solid to everybody: practice
-- is client-side and nothing told any other client who was practising. Now the
-- driver chooses (ghosted by default), their own client ghosts their car, and
-- every other client ghosts it off the server's `ghostPractice` list.
--
-- Practice also ENDS when a session or a derby starts. A practice lap is never
-- reported, so a driver still practising at the grid drove a race the server
-- never heard about (see practice_test.lua for the laps themselves).
--
-- Run from the repo root: lua5.3 tests/practice_ghost_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers, world = {}, {}, {}, {}
local OWN_ID, RIVAL_ID, THIRD_ID = 7, 42, 43
local OWN_PID, RIVAL_PID, THIRD_PID = 1, 2, 3
local OWNER = { [OWN_ID] = OWN_PID, [RIVAL_ID] = RIVAL_PID, [THIRD_ID] = THIRD_PID }

local Vec = {}
Vec.__index = Vec
Vec.__mul = function (v, s) return setmetatable({ x = v.x * s, y = v.y * s, z = v.z * s }, Vec) end
Vec.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, Vec) end
function Vec:cross(o)
  return setmetatable({ x = self.y * o.z - self.z * o.y, y = self.z * o.x - self.x * o.z,
                        z = self.x * o.y - self.y * o.x }, Vec)
end
local function v3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end

overlapsOBB_OBB = function (c1, x1, y1, z1, c2, x2, y2, z2)
  return math.abs(c1.x - c2.x) <= (x1.x + x2.x)
     and math.abs(c1.y - c2.y) <= (y1.y + y2.y)
     and math.abs(c1.z - c2.z) <= (z1.z + z2.z)
end
local AXES = { [0] = v3(1, 0, 0), [1] = v3(0, 1, 0), [2] = v3(0, 0, 1) }
local BB = {}
BB.__index = BB
function BB:getCenter() return self.c end
function BB:getHalfExtents() return self.he end
function BB:getAxis(i) return AXES[i] end

local function makeVehicle(id, x, y)
  local v = { id = id, x = x, y = y, z = 0, ghosted = nil, alpha = 1, cmds = 0 }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return v3(0, 1, 0) end
  function v:getDirectionVectorUp() return v3(0, 0, 1) end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation(nx, ny, nz) self.x, self.y, self.z = nx, ny, nz end
  function v:queueLuaCommand(cmd)
    if cmd == 'obj:setGhostEnabled(true)'  then self.ghosted = true;  self.cmds = self.cmds + 1 end
    if cmd == 'obj:setGhostEnabled(false)' then self.ghosted = false; self.cmds = self.cmds + 1 end
  end
  function v:setMeshAlpha(a) self.alpha = a end
  function v:getSpawnWorldOOBB()
    return setmetatable({ c = v3(self.x, self.y, self.z), he = v3(1.0, 2.2, 0.7) }, BB)
  end
  function v:getInitialLength() return 4.4 end
  function v:getInitialWidth() return 2.0 end
  function v:getInitialHeight() return 1.4 end
  return v
end

world[OWN_ID]   = makeVehicle(OWN_ID, 0, 0)
world[RIVAL_ID] = makeVehicle(RIVAL_ID, 500, 0)
world[THIRD_ID] = makeVehicle(THIRD_ID, -500, 0)
local own, rival, third = world[OWN_ID], world[RIVAL_ID], world[THIRD_ID]

getPlayerVehicle = function () return own end
be = { getPlayerVehicle = function () return own end, enterVehicle = function () end }
getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end
getObjectByID = function (id) return world[id] end
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function ()
    local list = {}
    for _, v in pairs(world) do list[#list + 1] = { ownerID = OWNER[v.id], gameVehicleID = v.id } end
    return list
  end,
}

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'
vec3 = function (x, y, z) return v3(x, y, z) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return OWN_PID end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function serverState(t)
  t.rmProtocol = 2
  t.drivers = t.drivers or {}
  t.maxResets = t.maxResets or -1
  handlers['RM_Update'](t)
end
local function frames(seconds)
  for _ = 1, math.floor(seconds / 0.1 + 0.5) do RM.onUpdate(0.1) end
end
local function count(event)
  local n = 0
  for _, s in ipairs(sent) do if s.event == event then n = n + 1 end end
  return n
end
local function last(event)
  for i = #sent, 1, -1 do if sent[i].event == event then return sent[i].payload end end
end
local function lastRoute()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end
local function lastNotice()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerNotice' then return hooks[i].payload.msg end
  end
end
local function practise()
  handlers['RM_Practice']({ on = true, layout = 'oval' })
end

serverState({ phase = 'waiting', ghostPractice = {} })
frames(0.5)

-- ---------------------------------------------------------------------------
-- The choice, as the start request carries it
-- ---------------------------------------------------------------------------
RM.practiceLayout('oval')
check(last('RM_LoadLayout') and last('RM_LoadLayout').ghost == true,
  'ghosted is the default, and the practice request says so')
RM.setPracticeGhost(false)
check(count('RM_PracticeGhost') == 0, 'changing it while not practising tells the server nothing')
RM.practiceLayout('oval')
check(last('RM_LoadLayout') and last('RM_LoadLayout').ghost == nil,
  'solid sends no ghost field: the server ghosts only on an explicit yes')
check(lastRoute() and lastRoute().practiceGhost == false, 'and the panel is told the choice')

-- ---------------------------------------------------------------------------
-- Solid: nothing is ghosted
-- ---------------------------------------------------------------------------
practise()
frames(2.5)
check(own.ghosted ~= true, 'practising solid leaves our car solid')
RM.endPractice()

-- ---------------------------------------------------------------------------
-- Ghosted: our own car, on our own client
-- ---------------------------------------------------------------------------
RM.setPracticeGhost(true)
sent = {}
practise()
check(own.ghosted == true,
  'practising ghosted makes our car intangible HERE too: it is simulated on this client')
check(own.alpha == 1, 'and leaves it looking solid to us: the fade is for everybody else')
check(rival.ghosted ~= true and third.ghosted ~= true,
  'nobody else is ghosted by our choice')

-- A reset reloads the vehicle's Lua VM, and setGhostEnabled with it.
own.ghosted = false
RM.onVehicleResetted(OWN_ID)
check(own.ghosted == true, 'a reset puts the practice ghost straight back')

-- And the sweep re-asserts it anyway, for anything that reloads a car quietly.
own.ghosted = false
frames(2.5)
check(own.ghosted == true, 'the two-second sweep re-asserts it')

-- Switched mid-practice: solid now, and the server is told.
RM.setPracticeGhost(false)
check(own.ghosted == false, 'switching to solid mid-practice gives the car its collisions back')
check(last('RM_PracticeGhost') and last('RM_PracticeGhost').on == false,
  'and tells the server, so the other clients stop ghosting it')
RM.setPracticeGhost(true)
check(own.ghosted == true and last('RM_PracticeGhost').on == true,
  'and switching back ghosts it again, and says so')

-- ---------------------------------------------------------------------------
-- Everyone else's, off the server's list
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', ghostPractice = { OWN_PID, RIVAL_PID } })
check(rival.ghosted == true, 'a driver on the practice list is a ghost on our screen')
check(rival.alpha < 1, 'and drawn faded, so we can see why we passed through them')
check(third.ghosted ~= true, 'a driver not on it stays solid')
check(own.ghosted == true and own.alpha == 1,
  'our own row on the list changes nothing: our car is ours to ghost')

rival.ghosted = false
RM.onVehicleResetted(RIVAL_ID)
check(rival.ghosted == true, 'their reset is re-asserted at once as well')

-- Dropped off the list while sitting inside us: stays a ghost until clear.
rival.x, rival.y = 0.5, 0.5
serverState({ phase = 'waiting', ghostPractice = { OWN_PID } })
check(rival.ghosted == true,
  'a practiser who stops while overlapping another car stays a ghost: no car goes solid with one inside it')
rival.x, rival.y = 500, 0
frames(0.5)
check(rival.ghosted == false, 'and goes solid as soon as the space is clear')

-- ---------------------------------------------------------------------------
-- Ending it
-- ---------------------------------------------------------------------------
sent = {}
RM.endPractice()
check(own.ghosted == false, 'End Practice gives our car its collisions back')
check(count('RM_PracticeEnd') == 1, 'and tells the server, so the other clients do too')
check(lastNotice() == 'Practice ended', 'and says so')

-- ---------------------------------------------------------------------------
-- A session starting ends practice
-- ---------------------------------------------------------------------------
practise()
check(own.ghosted == true, 'practising ghosted again')
sent = {}
serverState({ phase = 'grid', ghostPractice = {} })
check(lastRoute() and lastRoute().practice ~= true,
  'forming a grid ends practice: its laps would never reach the server')
check(own.ghosted == false, 'and takes the practice ghost off our car')
check(count('RM_PracticeEnd') == 1, 'and tells the server')
check(lastNotice() == 'Practice ended: a session is starting', 'and tells the driver why')
serverState({ phase = 'waiting', ghostPractice = {} })

-- ...and a derby forming does the same.
practise()
sent = {}
handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'forming' })
check(lastRoute() and lastRoute().practice ~= true, 'a derby forming ends practice too')
check(own.ghosted == false, 'with the ghost off')
check(count('RM_PracticeEnd') == 1, 'and the server told')
check(lastNotice() == 'Practice ended: a derby is starting', 'and the driver told why')
local ends = count('RM_PracticeEnd')
handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'running' })
check(count('RM_PracticeEnd') == ends, 'and the next derby broadcast does not end it twice')
handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'idle' })

if fails == 0 then
  print(('practice_ghost_test: %d checks, 0 failures'):format(checks))
else
  print(('practice_ghost_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
