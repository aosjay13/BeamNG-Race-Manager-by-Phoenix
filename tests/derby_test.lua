-- Headless test for the DEMO DERBY module in server/RaceManager/main.lua
-- (Lua 5.3, same as BeamMP), plus the client's ray-casting point-in-polygon
-- math (mirrored by hand; the GE extension cannot be dofile'd here).
-- Run from the repo root: lua5.3 tests/derby_test.lua
--
-- The derby is an isolated module: this test also asserts that a full derby
-- session leaves the circuit racing state machine completely untouched.

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil   -- last RM_Update payload (circuit racing)
local lastDerby = nil   -- last RM_DerbyUpdate payload
local lifeLost  = {}    -- [pid] = last RM_DerbyLifeLost payload
local lastArenas = nil  -- last RM_DerbyLayouts payload (saved arena list)
local lastChat = nil
local derbyGrid = {}    -- [pid] = start slot handed out at form-up
local derbyHeld = {}    -- [pid] = true when told to hold for the countdown
local derbyReleased = {} -- [pid] = last RM_ReleaseSpectate payload
local lastCountdown = nil  -- last RM_DerbyCountdown value (3..0, or -1 abort)
local timers = {}
local hostedMap = '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'       then lastState  = payload end
    if event == 'RM_DerbyUpdate'  then lastDerby  = payload end
    if event == 'RM_DerbyLayouts' then lastArenas = payload end
    if event == 'RM_DerbyGridAssign' then
      derbyGrid[target] = payload.slot
      if payload.hold then derbyHeld[target] = true end
    end
    if event == 'RM_DerbyCountdown' then lastCountdown = payload.count end
    if event == 'RM_DerbyLifeLost' then lifeLost[target] = payload end
    if event == 'RM_ReleaseSpectate' then derbyReleased[target] = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function (setting) return hostedMap end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
-- A derby now starts in TWO steps, the same shape the circuit races use: Form
-- Up places the field and holds it, then Start Derby releases it with a
-- countdown. Everywhere this suite used to press one button it drives the whole
-- procedure through here; the procedure ITSELF is asserted step by step in its
-- own section at the end of the file.
local DERBY_COUNTDOWN_STEPS = 3
local function startDerby(admin)
  RM_onDerbyFormUp(admin)
  RM_onDerbyStart(admin)
  for _ = 1, DERBY_COUNTDOWN_STEPS do RM_DerbyCountdownTick() end
end
local function derbyPlayer(name)
  for _, p in ipairs(lastDerby.players) do
    if p.name == name then return p end
  end
end

onInit()

-- Derby admin events now require authentication too. Confirm an unauthenticated
-- session is rejected, then log in the admin sessions the suite drives with.
RM_onDerbyFormUp(1)
check(lastDerby == nil, 'derby form-up ignored before authentication')
RM_onLogin(1, '{"password":"phoenix"}')
RM_onLogin(2, '{"password":"phoenix"}')
-- Login broadcasts circuit state (adminPresent); clear it so the isolation
-- assertion at the end still proves the derby itself never touches RM_Update.
lastState = nil

-- ---------------------------------------------------------------------------
-- Point-in-polygon (mirror of the client's derbyPointInPolygon)
-- ---------------------------------------------------------------------------
local function pointInPolygon(px, py, poly)
  local inside = false
  local n = #poly
  local j = n
  for i = 1, n do
    local xi, yi = poly[i].x, poly[i].y
    local xj, yj = poly[j].x, poly[j].y
    if ((yi > py) ~= (yj > py))
        and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

local square = { {x=0,y=0}, {x=100,y=0}, {x=100,y=100}, {x=0,y=100} }
check(pointInPolygon(50, 50, square) == true,   'PiP: center of square is inside')
check(pointInPolygon(150, 50, square) == false, 'PiP: east of square is outside')
check(pointInPolygon(-1, -1, square) == false,  'PiP: south-west corner outside')
check(pointInPolygon(99.9, 99.9, square) == true, 'PiP: near corner inside')

-- Non-convex L-shape: the notch must count as outside.
local lshape = { {x=0,y=0}, {x=100,y=0}, {x=100,y=50}, {x=50,y=50}, {x=50,y=100}, {x=0,y=100} }
check(pointInPolygon(25, 75, lshape) == true,  'PiP: inside the L arm')
check(pointInPolygon(75, 75, lshape) == false, 'PiP: inside the L notch is outside')
check(pointInPolygon(75, 25, lshape) == true,  'PiP: inside the L base')

-- Triangle (minimum polygon).
local tri = { {x=0,y=0}, {x=10,y=0}, {x=5,y=10} }
check(pointInPolygon(5, 3, tri) == true,  'PiP: inside triangle')
check(pointInPolygon(9, 8, tri) == false, 'PiP: outside triangle')

-- ---------------------------------------------------------------------------
-- Setup: timers + boundary markers
-- ---------------------------------------------------------------------------
RM_onDerbyRequestState(1)
check(lastDerby.derbyPhase == 'idle', 'derby starts idle')
check(lastDerby.oobLimit == 5 and lastDerby.demoLimit == 10, 'default timers 5s / 10s')

RM_onDerbySetConfig(1, '{"oobLimit":3,"demoLimit":8}')
check(lastDerby.oobLimit == 3 and lastDerby.demoLimit == 8, 'timers configurable')
RM_onDerbySetConfig(1, '{"oobLimit":0.1,"demoLimit":9999}')
check(lastDerby.oobLimit == 1 and lastDerby.demoLimit == 120, 'timers clamped to [1,120]')

-- NEITHER TIMER CAN BE SWITCHED OFF, and the stopped one is the one worth
-- guarding: it was made toggleable once and reverted the same day.
--
-- It is not a rule laid over the derby, it is the only thing that DETECTS A
-- WRECK -- nothing else can tell a destroyed car from a parked one. Off, a
-- finished driver sits in the arena as a live entrant forever, the field never
-- reduces, and no derby reaches a last man standing. Out of bounds cannot cover
-- for it: that fires on driving out, which a wreck cannot do.
--
-- Zero is therefore one second, not never. Here so the next person to have the
-- idea meets it as a failing test rather than as a race night.
RM_onDerbySetConfig(1, '{"oobLimit":0,"demoLimit":0}')
check(lastDerby.demoLimit == 1,
  'the stopped timer has no off switch: 0 floors to 1s (got '
    .. tostring(lastDerby.demoLimit) .. ')')
check(lastDerby.oobLimit == 1, 'and neither does out-of-bounds')
RM_onDerbySetConfig(1, '{"oobLimit":-5,"demoLimit":-5}')
check(lastDerby.demoLimit == 1 and lastDerby.oobLimit == 1,
  'a negative is a floor, not an off switch')

-- ---------------------------------------------------------------------------
-- LMS and DM
-- ---------------------------------------------------------------------------
-- Both modes enforce the SAME rules -- the stopped timer is the wreck detector
-- and neither works without it. The mode decides what an admin configures, plus
-- one rule underneath: LMS is one life.
--
-- That rule lives on the server, not in the panel, and these checks are why. A
-- client that sends lives without a mode, sends them in the wrong order, or is
-- too old to know about modes at all must not be able to leave a three-life
-- value sitting behind a mode whose panel does not show it.
check(lastDerby.derbyMode == 'lms', 'a derby starts in LMS')

RM_onDerbySetConfig(1, '{"mode":"dm","lives":3}')
check(lastDerby.derbyMode == 'dm' and lastDerby.lives == 3,
  'DM takes a lives setting')

RM_onDerbySetConfig(1, '{"mode":"lms"}')
check(lastDerby.lives == 1,
  'switching to LMS forces one life, so the rules match the panel (got '
    .. tostring(lastDerby.lives) .. ')')

RM_onDerbySetConfig(1, '{"mode":"lms","lives":5}')
check(lastDerby.lives == 1, 'and LMS refuses lives however they arrive')

RM_onDerbySetConfig(1, '{"lives":4}')
check(lastDerby.lives == 1,
  'including from a client that does not send a mode at all')

RM_onDerbySetConfig(1, '{"mode":"dm","lives":4}')
check(lastDerby.derbyMode == 'dm' and lastDerby.lives == 4,
  'and DM gets its lives back')

-- FROM DM, DELIBERATELY. Asked from LMS this check passes whether the garbled
-- value is ignored or falls back to a default, because the default IS lms --
-- it would be a check that cannot fail. Asked from DM, only ignoring it keeps
-- the mode where the admin left it.
RM_onDerbySetConfig(1, '{"mode":"nonsense"}')
check(lastDerby.derbyMode == 'dm',
  'an unrecognized mode leaves the setting alone rather than defaulting (got '
    .. tostring(lastDerby.derbyMode) .. ')')
check(lastDerby.lives == 4, 'and does not disturb the lives behind it')

-- LEFT IN DM AT ONE LIFE, which is exactly the behavior every check below this
-- point was written against: lives configurable, and a single stopped timer
-- ends a driver.
--
-- DM because lives only exist there -- restoring LMS would pin them at 1 and
-- fail a dozen checks that have nothing to do with modes. One life because
-- leaving four means nobody is eliminated on a first stopped timer and the
-- elimination, results and winner checks all fail instead.
RM_onDerbySetConfig(1, '{"mode":"dm","lives":1}')
check(lastDerby.lives == 1, 'fixture back to one life for the checks below')
RM_onDerbySetConfig(1, '{"oobLimit":5,"demoLimit":10}')

RM_onDerbyAddMarker(1, '{"x":0,"y":0,"z":50}')
RM_onDerbyAddMarker(1, '{"x":100,"y":0,"z":50}')
RM_onDerbyAddMarker(1, '{"x":100,"y":100,"z":50}')
check(#lastDerby.boundary == 3, 'three boundary markers placed')
RM_onDerbyAddMarker(1, 'not json at all')
RM_onDerbyAddMarker(1, '{"x":"nan","y":1}')
check(#lastDerby.boundary == 3, 'malformed marker payloads rejected')

RM_onDerbyClearBoundary(1)
check(#lastDerby.boundary == 0, 'boundary cleared')
RM_onDerbyAddMarker(1, '{"x":0,"y":0,"z":50}')
RM_onDerbyAddMarker(1, '{"x":100,"y":0,"z":50}')
RM_onDerbyAddMarker(1, '{"x":100,"y":100,"z":50}')
RM_onDerbyAddMarker(1, '{"x":0,"y":100,"z":50}')
check(#lastDerby.boundary == 4, 'boundary rebuilt with four markers')

-- Elimination reports before the derby starts are ignored.
RM_onDerbyDemolished(2)
check(lastDerby.derbyPhase == 'idle', 'pre-start elimination ignored')

-- ---------------------------------------------------------------------------
-- Run the derby: eliminations -> last man standing -> results export
-- ---------------------------------------------------------------------------
startDerby(1)
check(lastDerby.derbyPhase == 'running', 'derby running after start')
check(#lastDerby.players == 3, 'all three connected players participate')
check(timers['RM_DerbyTick'] == true, 'derby tick timer created')
check(derbyPlayer('Alice').status == 'alive', 'participants start alive')

-- Config and boundary are locked while running.
RM_onDerbySetConfig(1, '{"oobLimit":99,"demoLimit":99}')
check(lastDerby.oobLimit == 5, 'config locked during a running derby')
RM_onDerbyAddMarker(1, '{"x":1,"y":1,"z":1}')
RM_onDerbyClearBoundary(1)
check(#lastDerby.boundary == 4, 'boundary locked during a running derby')

for _ = 1, 12 do RM_DerbyTick() end  -- +12 s
check(lastDerby.derbyTime == 12, 'derby clock advances')

RM_onDerbyDemolished(2)              -- Bob stops moving at 12 s
check(derbyPlayer('Bob').status == 'eliminated'
  and derbyPlayer('Bob').reason == 'Demolished', 'Bob demolished')
check(lastDerby.derbyPhase == 'running', 'derby continues with two alive')
RM_onDerbyDemolished(2)              -- duplicate report is a no-op
check(derbyPlayer('Bob').elimTime == 12, 'duplicate elimination ignored')

for _ = 1, 8 do RM_DerbyTick() end   -- +8 s
lastChat = nil
RM_onDerbyDisqualified(3)            -- Cara leaves the arena at 20 s
check(derbyPlayer('Cara').status == 'eliminated'
  and derbyPlayer('Cara').reason == 'Disqualified', 'Cara disqualified')

-- Last man standing. The derby is DECIDED here but does not end on the instant:
-- a cool-down keeps the arena up for a few seconds so the result can be seen
-- among the wrecks -- and so a SOLO derby, where the win condition is true from
-- the moment it starts, has a running phase long enough to test anything in.
check(lastDerby.derbyPhase == 'running', 'the arena stays up for the cool-down')
check(type(lastChat) == 'string' and lastChat:find('ends in', 1, true),
  'and everyone is told the derby is decided and how long is left')
for _ = 1, 6 do RM_DerbyTick() end   -- past the 5 s cool-down
check(lastDerby.derbyPhase == 'finished', 'derby finished when one remains')
check(derbyPlayer('Alice').status == 'winner', 'Alice is the winner')
check(lastDerby.winner == 'Alice', 'winner broadcast')
check(timers['RM_DerbyTick'] == nil, 'derby tick timer canceled')
check(type(lastChat) == 'string' and lastChat:find('WINNER: Alice', 1, true),
  'chat announces the winner')

-- ---------------------------------------------------------------------------
-- Every driver gets their car back, STAGGERED.
--
-- A derby ends with almost the whole field removed -- that is what a derby is --
-- so it is the heaviest mass respawn in the mod. It was also the last one still
-- firing a bare broadcast that put every car back on the same tick, which is
-- precisely the refused-spawn / interpenetration case the ordering prevents.
-- It goes through the same respawnField the racing side uses now.
-- ---------------------------------------------------------------------------
local derbyBack, derbyOrders = 0, {}
for pid = 1, 3 do
  local r = derbyReleased[pid]
  if r then
    derbyBack = derbyBack + 1
    check(r.source == 'derby', 'driver ' .. pid .. ' is released by the DERBY, not the race')
    check(type(r.order) == 'number' and r.count == 3,
      'driver ' .. pid .. ' is told its place in the respawn order')
    if r.order then derbyOrders[r.order] = (derbyOrders[r.order] or 0) + 1 end
  end
end
check(derbyBack == 3, 'every derby participant gets their car back, not just the winner')
check(derbyOrders[1] == 1 and derbyOrders[2] == 1 and derbyOrders[3] == 1,
  'and the order is a clean 1..3 with no two cars spawning in the same slot')

-- Display/results order: winner first, then latest-out first.
check(lastDerby.players[1].name == 'Alice', 'P1 Alice (winner)')
check(lastDerby.players[2].name == 'Cara',  'P2 Cara (out last)')
check(lastDerby.players[3].name == 'Bob',   'P3 Bob (out first)')

-- Results .txt export
local RESULTS_DIR = 'Resources/Server/RaceManager/results'
local resultsPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
check(resultsPath ~= nil and resultsPath:find('derby_results_', 1, true),
  'derby results saved as derby_results_*.txt')
local rf = resultsPath and io.open(resultsPath, 'r')
check(rf ~= nil, 'derby results file exists on disk')
local content = rf and rf:read('a') or ''
if rf then rf:close() end
check(content:find('DEMO DERBY RESULTS', 1, true), 'results header present')
check(content:match('P1%s+Alice%s+WINNER'), 'Alice P1 WINNER in results')
check(content:match('P2%s+Cara%s+Disqualified%s+0:20'), 'Cara P2 disqualified at 0:20')
check(content:match('P3%s+Bob%s+Demolished%s+0:12'), 'Bob P3 demolished at 0:12')
check(content:find('LAST MAN STANDING', 1, true), 'winner tag present')
os.remove(resultsPath)

-- Post-finish elimination reports are ignored.
RM_onDerbyDisqualified(1)
check(derbyPlayer('Alice').status == 'winner', 'post-finish report ignored')

-- Reset back to setup.
RM_onDerbyEnd(1)
check(lastDerby.derbyPhase == 'idle' and #lastDerby.players == 0, 'End resets finished derby to idle')

-- ---------------------------------------------------------------------------
-- Second derby: admin force-end with several alive -> no winner
-- ---------------------------------------------------------------------------
startDerby(2)
for _ = 1, 5 do RM_DerbyTick() end
RM_onDerbyEnd(1)
check(lastDerby.derbyPhase == 'finished', 'admin ended the derby')
check(lastDerby.winner == nil, 'no winner when several were still alive')
-- Clean up the exported file from the forced end.
local p2 = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
if p2 then os.remove(p2) end
RM_onDerbyEnd(1)  -- back to idle

-- ---------------------------------------------------------------------------
-- Disconnect during a derby eliminates the player (as Disqualified)
-- ---------------------------------------------------------------------------
startDerby(1)
for _ = 1, 3 do RM_DerbyTick() end
RM_Derby_onPlayerDisconnect(3)
check(derbyPlayer('Cara').status == 'eliminated'
  and derbyPlayer('Cara').reason == 'Disqualified', 'disconnect counts as disqualified')
check(lastDerby.derbyPhase == 'running', 'derby continues with two alive')
RM_onDerbyDemolished(1)
for _ = 1, 6 do RM_DerbyTick() end   -- past the cool-down
check(lastDerby.derbyPhase == 'finished' and lastDerby.winner == 'Bob',
  'Bob wins the third derby')
local p3 = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
if p3 then os.remove(p3) end

-- ---------------------------------------------------------------------------
-- Saved arenas: an arena is its boundary polygon plus both timers, stored per
-- map on the server exactly the way a track layout is.
-- ---------------------------------------------------------------------------
RM_onDerbyEnd(1)                     -- back to idle so the arena can be edited
RM_onDerbyClearBoundary(1)
RM_onDerbyAddMarker(1, '{"x":0,"y":0,"z":10}')
RM_onDerbyAddMarker(1, '{"x":60,"y":0,"z":10}')
RM_onDerbyAddMarker(1, '{"x":60,"y":60,"z":10}')
RM_onDerbyAddMarker(1, '{"x":0,"y":60,"z":10}')
RM_onDerbySetConfig(1, '{"oobLimit":7,"demoLimit":12}')

-- Unauthenticated saves are dropped like every other admin command.
lastArenas = nil
RM_onDerbySaveLayout(9, '{"name":"Pit Arena","boundary":[{"x":0,"y":0,"z":0},{"x":1,"y":0,"z":0},{"x":1,"y":1,"z":0}]}')
check(lastArenas == nil, 'arena save ignored before authentication')

RM_onDerbySaveLayout(1, '{"name":"Pit Arena","boundary":[{"x":0,"y":0,"z":10},'
  .. '{"x":60,"y":0,"z":10},{"x":60,"y":60,"z":10},{"x":0,"y":60,"z":10}],'
  .. '"oobLimit":7,"demoLimit":12}')
check(lastArenas ~= nil and #lastArenas.layouts == 1, 'the arena is saved and listed')
check(lastArenas.map == 'gridmap_v2', 'arenas are listed for the hosted map')
check(#lastArenas.layouts[1].boundary == 4, 'the boundary polygon is stored')
check(lastArenas.layouts[1].oobLimit == 7 and lastArenas.layouts[1].demoLimit == 12,
  'both timers are stored with the arena')

-- Too few markers is not an arena.
RM_onDerbySaveLayout(1, '{"name":"Sliver","boundary":[{"x":0,"y":0,"z":0},{"x":1,"y":0,"z":0}]}')
check(#lastArenas.layouts == 1, 'an arena with fewer than 3 markers is rejected')

-- Same name overwrites rather than duplicating (the edit workflow).
RM_onDerbySaveLayout(1, '{"name":"pit arena","boundary":[{"x":0,"y":0,"z":10},'
  .. '{"x":20,"y":0,"z":10},{"x":20,"y":20,"z":10}],"oobLimit":3,"demoLimit":4}')
check(#lastArenas.layouts == 1 and #lastArenas.layouts[1].boundary == 3,
  'saving the same name overwrites the arena')

-- Loading adopts the boundary and the timers and pushes them to every client.
RM_onDerbyClearBoundary(1)
check(#lastDerby.boundary == 0, 'boundary cleared before the load')
RM_onDerbyLoadLayout(1, '{"name":"Pit Arena"}')
check(#lastDerby.boundary == 3, 'loading an arena restores its boundary')
check(lastDerby.oobLimit == 3 and lastDerby.demoLimit == 4,
  'loading an arena restores its timers')

-- Strict map filter, same as track layouts.
hostedMap = '/levels/east_coast_usa/info.json'
RM_onDerbyRequestLayouts(1)
check(#lastArenas.layouts == 0, 'arenas from another map are not listed')
hostedMap = '/levels/gridmap_v2/info.json'
RM_onDerbyRequestLayouts(1)
check(#lastArenas.layouts == 1, 'and come back when that map is hosted again')

-- An arena cannot be swapped under a running derby.
startDerby(1)
RM_onDerbyClearBoundary(1)              -- also refused while running
RM_onDerbyLoadLayout(1, '{"name":"Pit Arena"}')
check(#lastDerby.boundary == 3, 'the arena cannot change while a derby runs')
RM_onDerbyEnd(1)
RM_onDerbyEnd(1)                        -- finished -> idle

-- ---------------------------------------------------------------------------
-- The rectangle arena: a second EDITOR, not a second boundary
-- ---------------------------------------------------------------------------
-- An arena can be authored two ways -- driving the perimeter and dropping a
-- marker at each corner, or standing in the middle and pulling a rectangle out
-- around you. Both produce the SAME thing: an ordered polygon in
-- derby.boundary, which is the only representation any gameplay code has ever
-- read. Everything below is really one assertion said several ways: the mode
-- decides which controls work, and never what the arena IS.
RM_onDerbyClearBoundary(1)
check(lastDerby.boundaryMode == 'polygon',
  'a cleared arena is back to the drive-and-place editor')

-- With nothing placed there is nothing to fit a rectangle around, so the client
-- sends the position of the admin's car as the center.
RM_onDerbySetBoundaryMode(9, '{"mode":"rect","cx":0,"cy":0,"cz":5}')
check(lastDerby.boundaryMode == 'polygon', 'mode switch ignored before authentication')
RM_onDerbySetBoundaryMode(1, '{"mode":"rect","cx":10,"cy":20,"cz":5}')
check(lastDerby.boundaryMode == 'rect', 'the rectangle editor can be switched on')
check(#lastDerby.boundary == 4, 'a rectangle is four derived corners')
check(lastDerby.shape.cx == 10 and lastDerby.shape.cy == 20,
  'centerd where the car was standing')

-- Size. The client sends half-extents; the panel's sliders are the full span.
RM_onDerbySetShape(1, '{"halfW":50,"halfL":30}')
local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
local zs = {}
for _, m in ipairs(lastDerby.boundary) do
  minx = math.min(minx, m.x); maxx = math.max(maxx, m.x)
  miny = math.min(miny, m.y); maxy = math.max(maxy, m.y)
  zs[#zs + 1] = m.z
end
check(maxx - minx == 100 and maxy - miny == 60,
  'the extents come out as a 100 x 60 m rectangle')
check(zs[1] == 5 and zs[2] == 5 and zs[3] == 5 and zs[4] == 5,
  'every corner sits at the center z -- the arena is a flat plane')

-- The corners have to be a RING. A bowtie would still enclose an area to the
-- eye and would fail point-in-polygon in the middle of it.
check(pointInPolygon(10, 20, lastDerby.boundary), 'the center is inside the arena')
check(pointInPolygon(55, 20, lastDerby.boundary), 'and so is a point near the long edge')
check(not pointInPolygon(70, 20, lastDerby.boundary), 'a point beyond the edge is outside')

-- Rotation turns the same rectangle. A quarter turn swaps width and length,
-- which is why the panel only offers 0-90 degrees.
RM_onDerbySetShape(1, '{"rot":1.5707963267948966}')
minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
for _, m in ipairs(lastDerby.boundary) do
  minx = math.min(minx, m.x); maxx = math.max(maxx, m.x)
  miny = math.min(miny, m.y); maxy = math.max(maxy, m.y)
end
check(math.abs((maxx - minx) - 60) < 1e-6 and math.abs((maxy - miny) - 100) < 1e-6,
  'a quarter turn swaps the rectangle over')
RM_onDerbySetShape(1, '{"rot":0}')

-- Out-of-range values are clamped rather than refused: every one of these
-- arrives off a slider an admin can also type into.
RM_onDerbySetShape(1, '{"halfW":9000,"halfL":-4}')
check(lastDerby.shape.halfW == 250 and lastDerby.shape.halfL == 5,
  'extents are clamped to the allowed range')
RM_onDerbySetShape(1, '{"halfW":50,"halfL":30}')

-- Wall height is visual and belongs to BOTH editors, so it never switches modes
-- and never touches the boundary.
RM_onDerbySetShape(1, '{"wallHeight":14}')
check(lastDerby.wallHeight == 14, 'wall height is server-owned and broadcast')
check(#lastDerby.boundary == 4, 'and changes nothing about the boundary')

-- A rectangle's corners are derived, so the marker tools have no answer for one
-- and are refused. The UI hides them; this is the authoritative half.
RM_onDerbyAddMarker(1, '{"x":500,"y":500,"z":0}')
check(#lastDerby.boundary == 4, 'a marker cannot be added to a rectangle')
RM_onDerbyMoveMarker(1, '{"index":1,"x":900,"y":900,"z":0}')
check(lastDerby.boundary[1].x ~= 900, 'and a rectangle corner cannot be dragged')
RM_onDerbyRemoveMarker(1, '{"index":1}')
check(#lastDerby.boundary == 4, 'nor deleted')

-- Switching back keeps the work: the four corners stay exactly where they are
-- and simply become ordinary, editable markers again.
RM_onDerbySetBoundaryMode(1, '{"mode":"polygon"}')
check(lastDerby.boundaryMode == 'polygon' and #lastDerby.boundary == 4,
  'leaving rectangle mode keeps the corners as markers')
check(lastDerby.shape == nil, 'and drops the shape that derived them')
RM_onDerbyMoveMarker(1, '{"index":1,"x":-90,"y":-90,"z":5}')
check(lastDerby.boundary[1].x == -90, 'which are editable again')

-- ...and switching TO rectangle mode with an arena already placed fits one
-- around it rather than throwing it away.
RM_onDerbySetBoundaryMode(1, '{"mode":"rect"}')
check(lastDerby.boundaryMode == 'rect' and lastDerby.shape ~= nil,
  'a placed arena can be adopted by the rectangle editor')
check(lastDerby.shape.halfW > 50, 'the rectangle is fitted around what was there')

-- A rectangle saves and loads as a rectangle, and comes back editable.
RM_onDerbySetShape(1, '{"halfW":40,"halfL":25,"rot":0.5,"wallHeight":9}')
RM_onDerbySaveLayout(1, '{"name":"Bowl","boundary":[{"x":0,"y":0,"z":5},'
  .. '{"x":80,"y":0,"z":5},{"x":80,"y":50,"z":5},{"x":0,"y":50,"z":5}],'
  .. '"boundaryMode":"rect","wallHeight":9,'
  .. '"shape":{"cx":40,"cy":25,"cz":5,"halfW":40,"halfL":25,"rot":0.5}}')
RM_onDerbyClearBoundary(1)
check(lastDerby.boundaryMode == 'polygon' and #lastDerby.boundary == 0,
  'cleared back to an empty drive-and-place arena')
RM_onDerbyLoadLayout(1, '{"name":"Bowl"}')
check(lastDerby.boundaryMode == 'rect', 'a saved rectangle loads as a rectangle')
check(lastDerby.shape.halfW == 40 and lastDerby.shape.halfL == 25,
  'with its extents intact')
check(lastDerby.wallHeight == 9, 'and its wall height')
check(#lastDerby.boundary == 4, 'and four corners re-derived from the shape')

-- The compatibility case that matters: an arena saved before any of this
-- existed has no boundaryMode, no shape and no wallHeight. It must load as
-- exactly what it has always been -- a drive-and-place arena -- with no
-- migration step and nothing lost.
RM_onDerbyLoadLayout(1, '{"name":"Pit Arena"}')
check(lastDerby.boundaryMode == 'polygon' and lastDerby.shape == nil,
  'a pre-rectangle saved arena still loads as drive-and-place')
check(#lastDerby.boundary == 3, 'with its markers untouched')
RM_onDerbyMoveMarker(1, '{"index":1,"x":-5,"y":-5,"z":10}')
check(lastDerby.boundary[1].x == -5, 'and still fully editable')

-- Neither editor may be touched once a field is standing on the grid.
RM_onDerbyFormUp(1)
RM_onDerbySetBoundaryMode(1, '{"mode":"rect","cx":0,"cy":0,"cz":0}')
check(lastDerby.boundaryMode == 'polygon',
  'the arena editor cannot be switched under a formed-up field')
RM_onDerbySetShape(1, '{"wallHeight":30}')
check(lastDerby.wallHeight ~= 30, 'and nothing about the arena can be resized')
RM_onDerbyEnd(1)
RM_onDerbyEnd(1)
-- Hand the arena store back the way this section found it: the sections below
-- count the saved list and index into it.
RM_onDerbyDeleteLayout(1, '{"name":"Bowl"}')
check(#lastArenas.layouts == 1, 'the rectangle arena is cleaned up again')
local ap = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
if ap then os.remove(ap) end

RM_onDerbyDeleteLayout(1, '{"name":"Pit Arena"}')
check(#lastArenas.layouts == 0, 'an arena can be deleted')

-- ---------------------------------------------------------------------------
-- Derby editor additions: reset allowance, starting grid, arena round trip
-- ---------------------------------------------------------------------------
RM_onDerbySetConfig(1, '{"oobLimit":5,"demoLimit":10,"maxResets":2}')
check(lastDerby.maxResets == 2, 'derby reset allowance is configurable')
RM_onDerbySetConfig(1, '{"oobLimit":5,"demoLimit":10,"maxResets":-5}')
check(lastDerby.maxResets == -1, 'any negative allowance normalizes to unlimited')
RM_onDerbySetConfig(1, '{"oobLimit":5,"demoLimit":10,"maxResets":2}')

RM_onDerbyAddStart(9, '{"x":1,"y":1,"z":0,"hx":0,"hy":1}')  -- not authenticated
check(#lastDerby.startPositions == 0, 'unauthenticated start placement is refused')
RM_onDerbyAddStart(1, '{"x":10,"y":20,"z":0,"hx":0,"hy":1}')
RM_onDerbyAddStart(1, '{"x":14,"y":20,"z":0,"hx":0,"hy":1}')
check(#lastDerby.startPositions == 2, 'derby start positions accumulate in slot order')
check(lastDerby.startPositions[1].x == 10 and lastDerby.startPositions[1].hy == 1,
  'a start position keeps its placement and facing')

-- The grid and the allowance travel with a saved arena.
RM_onDerbySaveLayout(1, '{"name":"Grid Arena","boundary":[{"x":0,"y":0,"z":0},'
  .. '{"x":60,"y":0,"z":0},{"x":60,"y":60,"z":0}],"oobLimit":5,"demoLimit":10,'
  .. '"maxResets":2,"startPositions":[{"x":10,"y":20,"z":0,"hx":0,"hy":1},'
  .. '{"x":14,"y":20,"z":0,"hx":0,"hy":1}]}')
RM_onDerbyClearStarts(1)
RM_onDerbySetConfig(1, '{"oobLimit":5,"demoLimit":10,"maxResets":-1}')
check(#lastDerby.startPositions == 0 and lastDerby.maxResets == -1,
  'start grid cleared and allowance back to unlimited before the reload')
RM_onDerbyLoadLayout(1, '{"name":"Grid Arena"}')
check(#lastDerby.startPositions == 2, 'loading an arena restores its starting grid')
check(lastDerby.maxResets == 2, 'and its reset allowance')

-- ---------------------------------------------------------------------------
-- Editing one placed marker / one placed start slot
--
-- Placement used to be final: fixing marker 2 of twelve meant Clear Boundary
-- and driving the whole perimeter again. Both lists are now editable entry by
-- entry, and what every check below is really asserting is that exactly ONE
-- entry changes -- the failure this replaces was a bulk operation.
-- ---------------------------------------------------------------------------
check(#lastDerby.boundary == 3 and #lastDerby.startPositions == 2,
  'editing starts from the loaded arena: 3 markers, 2 slots')

-- Admin commands like every other one.
RM_onDerbyMoveMarker(9, '{"index":1,"x":5,"y":5,"z":0}')
RM_onDerbyRemoveMarker(9, '{"index":1}')
RM_onDerbyMoveStart(9, '{"index":1,"x":5,"y":5,"z":0,"hx":0,"hy":1}')
RM_onDerbyRemoveStart(9, '{"index":1}')
check(#lastDerby.boundary == 3 and #lastDerby.startPositions == 2,
  'unauthenticated marker/slot edits are refused')

local before1, before3 = lastDerby.boundary[1].x, lastDerby.boundary[3].x
RM_onDerbyMoveMarker(1, '{"index":2,"x":77,"y":88,"z":9}')
check(lastDerby.boundary[2].x == 77 and lastDerby.boundary[2].y == 88
  and lastDerby.boundary[2].z == 9, 'a marker moves to the position sent')
check(#lastDerby.boundary == 3 and lastDerby.boundary[1].x == before1
  and lastDerby.boundary[3].x == before3, 'and nothing else in the perimeter moves')

RM_onDerbyMoveMarker(1, '{"index":9,"x":1,"y":1,"z":1}')
RM_onDerbyMoveMarker(1, '{"index":2,"x":"nan","y":1,"z":1}')
RM_onDerbyMoveMarker(1, '{"x":1,"y":1,"z":1}')
RM_onDerbyMoveMarker(1, 'not json at all')
check(lastDerby.boundary[2].x == 77 and #lastDerby.boundary == 3,
  'an index that does not exist, a missing index and a malformed payload are no-ops')

RM_onDerbyRemoveMarker(1, '{"index":2}')
check(#lastDerby.boundary == 2, 'deleting a marker shortens the perimeter')
check(lastDerby.boundary[1].x == before1 and lastDerby.boundary[2].x == before3,
  'and the survivors keep their order, closing up around the gap')
RM_onDerbyRemoveMarker(1, '{"index":7}')
check(#lastDerby.boundary == 2, 'deleting an index that does not exist is a no-op')
-- Dropping under three markers is allowed. The arena is then not a polygon --
-- exactly the state it is in before the third marker is ever placed, and after
-- Clear Boundary -- and the minimum is enforced where it already was: an arena
-- with fewer cannot be saved.
RM_onDerbyRemoveMarker(1, '{"index":1}')
RM_onDerbyRemoveMarker(1, '{"index":1}')
check(#lastDerby.boundary == 0, 'the last markers can still be deleted one at a time')
RM_onDerbySaveLayout(1, '{"name":"Too Small","boundary":[{"x":0,"y":0,"z":0}]}')
RM_onDerbyRequestLayouts(1)
check(#lastArenas.layouts == 1, 'and an under-three arena still cannot be saved')

-- Start slots: the same two operations, plus a facing that travels with a move.
RM_onDerbyMoveStart(1, '{"index":2,"x":30,"y":40,"z":1,"hx":1,"hy":0}')
check(lastDerby.startPositions[2].x == 30 and lastDerby.startPositions[2].hx == 1,
  'a start slot moves, taking the facing it was moved to')
check(lastDerby.startPositions[1].x == 10, 'and slot 1 is untouched by slot 2 moving')
RM_onDerbyRemoveStart(1, '{"index":1}')
check(#lastDerby.startPositions == 1 and lastDerby.startPositions[1].x == 30,
  'deleting slot 1 promotes the slot behind it to pole')

-- Editing the live arena must not rewrite the SAVED one it was loaded from:
-- the two used to share a table, so moving a marker edited the file's copy too.
RM_onDerbyRequestLayouts(1)
local saved = lastArenas.layouts[1]
check(saved.name == 'Grid Arena' and #saved.boundary == 3 and saved.boundary[2].x == 60,
  'the saved arena is untouched by every edit made to the loaded one')

-- Rebuild the arena the rest of the suite runs on: 3 markers, 2 slots.
RM_onDerbyLoadLayout(1, '{"name":"Grid Arena"}')
check(#lastDerby.boundary == 3 and #lastDerby.startPositions == 2,
  'arena reloaded intact for the rest of the suite')

-- Start Derby hands each participant a slot (pid order; the field can be
-- bigger than the placed grid).
startDerby(1)
check(derbyGrid[1] == 1 and derbyGrid[2] == 2, 'participants are stood on slots 1 and 2')
check(derbyGrid[3] == nil, 'a driver beyond the placed grid gets no slot')

-- Individual edits are locked from form-up onward, exactly like Clear Boundary
-- and Load Arena: the ground cannot move under a field standing on it.
RM_onDerbyMoveMarker(1, '{"index":1,"x":-99,"y":-99,"z":0}')
RM_onDerbyRemoveMarker(1, '{"index":1}')
RM_onDerbyMoveStart(1, '{"index":1,"x":-99,"y":-99,"z":0,"hx":0,"hy":1}')
RM_onDerbyRemoveStart(1, '{"index":1}')
check(#lastDerby.boundary == 3 and lastDerby.boundary[1].x == 0,
  'markers cannot be moved or deleted while a derby is under way')
check(#lastDerby.startPositions == 2 and lastDerby.startPositions[1].x == 10,
  'and neither can start slots')

-- Reset tally: counted per driver, capped at the allowance.
RM_onDerbyVehicleReset(2)
check(derbyPlayer('Bob').resets == 1, 'a derby reset is tallied for the standings')
RM_onDerbyVehicleReset(2)
RM_onDerbyVehicleReset(2)
check(derbyPlayer('Bob').resets == 2, 'the tally can never pass the allowance')

RM_onDerbyEnd(1)
RM_onDerbyEnd(1)                        -- finished -> idle
local gp = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
if gp then os.remove(gp) end
RM_onDerbyDeleteLayout(1, '{"name":"Grid Arena"}')

-- ---------------------------------------------------------------------------
-- Isolation: the whole derby session never touched circuit racing state
-- ---------------------------------------------------------------------------
check(lastState == nil, 'no RM_Update was ever broadcast by derby activity')
RM_onRequestState(1)
check(lastState.phase == 'waiting', 'racing state machine still waiting')
check(lastState.totalLaps == 5, 'race distance untouched by the derby')

-- ---------------------------------------------------------------------------
-- Display names carry over to the derby board and the derby results
-- ---------------------------------------------------------------------------
-- Deliberately the LAST section in this file. An alias is set on the racing
-- record -- that is the only place an admin can reach one -- so setting it
-- broadcasts RM_Update, which would trip the isolation assertion above. That
-- assertion is about derby activity never touching racing state, and this is
-- an explicit admin action, not derby activity.
--
-- The derby keeps its own player table with its own copy of the name, so the
-- board and the results have to resolve through the racing record by id rather
-- than carrying a second copy that can drift.
local function derbyRec(id)
  for _, p in ipairs(lastDerby.players) do
    if p.id == id then return p end
  end
end

for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetAlias(1, '{"target":2,"alias":"Bob Smash"}')
startDerby(1)
check(derbyRec(2) ~= nil, 'the renamed driver is on the derby board')
check(derbyRec(2).alias == 'Bob Smash', 'the display name reaches the derby board')
check(derbyRec(2).name == 'Bob', 'the real name is still carried alongside')
check(derbyRec(1).alias == nil, 'a driver with no display name is unaffected')

-- Clearing has to propagate too: a stamped copy would go sticky and leave a
-- name the admin removed sitting on the standings forever.
RM_onSetAlias(1, '{"target":2,"alias":""}')
RM_onDerbyRequestState(1)
check(derbyRec(2).alias == nil, 'clearing a display name clears it on the derby board')

-- ...and into the exported derby results.
RM_onSetAlias(1, '{"target":2,"alias":"Bob Smash"}')
RM_onDerbyRequestState(1)
RM_onDerbyDisqualified(1)
RM_onDerbyDisqualified(3)
for _ = 1, 6 do RM_DerbyTick() end   -- past the cool-down
check(lastDerby.winner == 'Bob Smash', 'the winner is announced under the display name')
local dpath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
check(dpath ~= nil, 'the derby results path was announced')
if dpath then
  local rf = io.open(dpath, 'r')
  local dtext = rf and rf:read('*a')
  if rf then rf:close() end
  check(dtext and dtext:find('Bob Smash', 1, true) ~= nil,
    'the derby results file records the display name')
  check(dtext and dtext:find('[Bob]', 1, true) ~= nil,
    'the derby results file also records the real name, so it stays traceable')
  os.remove(dpath)
end

-- ---------------------------------------------------------------------------
-- Derby entry: the same one switch the race uses
-- ---------------------------------------------------------------------------
-- A DERBY HAS NO ENTRY MODE OF ITS OWN. It used to, and it read the RACING
-- record's opt-in flag to resolve it, so a driver had to join the race to be put
-- in a derby. One decision covers both now: if you are spectating you sit out
-- whatever is running. The derby still only READS the racing entry list, which
-- is why nobody has to opt in twice.
RM_onDerbyEnd(1)   -- back to setup from the section above
RM_onDerbyEnd(1)

check(lastDerby.entrants == 3, 'everyone connected is in the derby field by default')

-- Everybody sits out: no field, and the derby must not start.
RM_onSetSpectating(1, '{"spectating":true}')
RM_onSetSpectating(2, '{"spectating":true}')
RM_onSetSpectating(3, '{"spectating":true}')
check(lastDerby.entrants == 0, 'a server where everyone spectates has no derby field')
startDerby(1)
check(lastDerby.derbyPhase ~= 'running', 'a derby with no entrants does not start')

-- One driver comes back: only they are in the field.
RM_onSetSpectating(2, '{"spectating":false}')
check(lastDerby.entrants == 1, 'the entrant count follows the racing entry list')
startDerby(1)
check(lastDerby.derbyPhase == 'running', 'the derby starts once somebody is in')
local inField = 0
for _, p in ipairs(lastDerby.players) do inField = inField + 1 end
check(inField == 1, 'only the driver who is racing is a participant')
check(derbyRec(2) ~= nil, 'the driver who is in is in the field')
check(derbyRec(1) == nil, 'a connected player who is spectating is left out')

-- The field cannot change underneath a running derby.
RM_onSetSpectating(1, '{"spectating":false}')
check(lastDerby.entrants == 1, 'entry is locked while a derby is running')
RM_onDerbyEnd(1)
RM_onDerbyEnd(1)

-- Everyone back in: the full field turns up again.
RM_onSetSpectating(3, '{"spectating":false}')
startDerby(1)
inField = 0
for _, p in ipairs(lastDerby.players) do inField = inField + 1 end
check(inField == 3, 'every connected player is in the field again')
RM_onDerbyEnd(1)
RM_onDerbyEnd(1)

-- ---------------------------------------------------------------------------
-- Form up and countdown: the derby's own start procedure
-- ---------------------------------------------------------------------------
-- The field is placed and HELD at Form Up, then released by a countdown, the
-- same two-step shape the circuit races use. The hold is imposed and lifted by
-- the client, so what is asserted here is the server contract that drives it:
-- the phases, the hold flag on the grid assign, and the countdown broadcast.
RM_onDerbyEnd(1)
RM_onDerbyEnd(1)
check(lastDerby.derbyPhase == 'idle', 'derby back to idle before the start-procedure checks')

-- Start Derby without forming up first is refused.
RM_onDerbyStart(1)
check(lastDerby.derbyPhase == 'idle', 'Start Derby does nothing until the field is formed up')

-- Form Up places and holds everyone.
derbyGrid = {}
derbyHeld = {}
lastCountdown = nil    -- earlier sections ran countdowns of their own
RM_onDerbyFormUp(1)
check(lastDerby.derbyPhase == 'forming', 'Form Up puts the derby in the forming phase')
local held = 0
for _ in pairs(derbyHeld) do held = held + 1 end
check(held == 3, 'every participant is told to hold, not just those with a slot')
check(lastCountdown == nil, 'forming up does not start the countdown on its own')

-- Rules and arena edits are locked from form-up onward, not just once running.
local oobBefore = lastDerby.oobLimit
RM_onDerbySetConfig(1, '{"oob":42,"demo":42,"maxResets":-1}')
check(lastDerby.oobLimit == oobBefore, 'derby rules are locked once the field is formed')
local markersBefore = #lastDerby.boundary
RM_onDerbyAddMarker(1, '{"x":99,"y":99,"z":0}')
check(#lastDerby.boundary == markersBefore, 'the arena cannot be edited once the field is formed')

-- Start Derby runs a countdown, and only GO puts it into running.
RM_onDerbyStart(1)
check(lastDerby.derbyPhase == 'countdown', 'Start Derby begins the countdown')
check(lastCountdown == 3, 'the countdown starts at 3')
RM_DerbyCountdownTick()
check(lastCountdown == 2, 'the countdown ticks down')
check(lastDerby.derbyPhase == 'countdown', 'still counting down, not running')
RM_DerbyCountdownTick()
check(lastCountdown == 1, 'the countdown reaches 1')
RM_DerbyCountdownTick()
check(lastCountdown == 0, 'GO is broadcast, which is what releases the held cars')
check(lastDerby.derbyPhase == 'running', 'the derby is running only after GO')

-- Aborting before GO releases the field and records no result.
RM_onDerbyEnd(1)          -- end the running derby from above
RM_onDerbyEnd(1)          -- clear finished -> idle
lastCountdown = nil
RM_onDerbyFormUp(1)
check(lastDerby.derbyPhase == 'forming', 'formed up again')
RM_onDerbyEnd(1)
check(lastDerby.derbyPhase == 'idle', 'aborting from form-up goes straight back to idle')
check(lastCountdown == -1, 'the abort broadcasts a countdown cancel, which frees the held cars')
check(lastDerby.winner == nil, 'an aborted start records no winner')

-- Admin-only, like everything else in the derby.
RM_onDerbyFormUp(3)
check(lastDerby.derbyPhase == 'idle', 'a non-admin cannot form up the field')

-- ===========================================================================
-- LIVES: being counted out puts a driver back on the grid, not out of the derby
-- ===========================================================================
-- The stopped timer expiring used to be the end of somebody's derby full stop.
-- With lives set above 1 it spends one and sends them back to the slot they
-- started from instead, so a derby is a scrap you can come back from.
--
-- Out of bounds is deliberately NOT covered by lives: leaving the arena is a
-- choice in a way that being wrecked is not, and a driver with lives in hand
-- could otherwise use the boundary as a free teleport back into the fight.
do
  RM_onDerbyEnd(1)
  RM_onDerbySetConfig(1, '{"oobLimit":3,"demoLimit":8,"lives":3}')
  check(lastDerby.lives == 3, 'lives are configurable and broadcast')
  RM_onDerbySetConfig(1, '{"lives":0}')
  check(lastDerby.lives == 1, 'nought lives is floored to 1: it would empty the field')
  RM_onDerbySetConfig(1, '{"lives":99}')
  check(lastDerby.lives == 9, 'and a silly number is capped')

  RM_onDerbySetConfig(1, '{"oobLimit":3,"demoLimit":8,"lives":3}')
  lifeLost = {}
  RM_onDerbyFormUp(1)
  RM_onDerbyStart(1)
  for _ = 1, 4 do RM_DerbyCountdownTick() end
  check(lastDerby.derbyPhase == 'running', 'the derby is running')
  check(derbyPlayer('Alice').lives == 3, 'every driver starts on the full allowance')

  -- First time counted out: a life goes, and the driver does not.
  RM_onDerbyDemolished(2)
  check(derbyPlayer('Bob').status == 'alive', 'a driver with lives left is NOT eliminated')
  check(derbyPlayer('Bob').lives == 2, 'a life is spent')
  check(lifeLost[2] ~= nil, 'and they are told')
  check(lifeLost[2] and lifeLost[2].lives == 2, 'with how many are left')
  check(lifeLost[2] and lifeLost[2].slot == derbyGrid[2],
    'and sent back to the slot they STARTED from, not a recomputed one')

  RM_onDerbyDemolished(2)
  check(derbyPlayer('Bob').lives == 1, 'a second one goes the same way')
  check(derbyPlayer('Bob').status == 'alive', 'still in')

  -- The last one is the end of it.
  lifeLost = {}
  RM_onDerbyDemolished(2)
  check(derbyPlayer('Bob').status == 'eliminated', 'out of lives is out of the derby')
  check(derbyPlayer('Bob').reason == 'Demolished', 'and the reason is recorded')
  check(lifeLost[2] == nil, 'with no respawn offered')

  -- OUT OF BOUNDS IGNORES LIVES ENTIRELY.
  check(derbyPlayer('Cara').lives == 3, 'Cara still has her full allowance')
  RM_onDerbyDisqualified(3)
  check(derbyPlayer('Cara').status == 'eliminated',
    'leaving the arena eliminates outright, whatever lives are in hand')
  check(derbyPlayer('Cara').lives == 3, 'and spends none of them')
end

-- ---------------------------------------------------------------------------
-- A DERBY ENDED DURING ITS COOL-DOWN MUST NOT POISON THE NEXT ONE
-- ---------------------------------------------------------------------------
-- Reported from a race night as two separate faults -- "the hold sets the
-- handbrake" and "the demolished timer starts immediately" -- one derby after
-- the one that actually caused it.
--
-- derbyOver is what tells every client to stand its car down. It is derived
-- from endsAt, which is set when a derby is DECIDED and used to be cleared only
-- by the tick that runs the cool-down out. Pressing End Derby during those few
-- seconds skipped that line, and nothing else ever cleared it: not form-up, not
-- GO. The next derby was born already over, so every client froze and applied
-- the handbrake the moment it started -- and a car that cannot move trips the
-- stopped timer seconds later.
do
  RM_onDerbyEnd(1)                       -- whatever the section above left
  RM_onDerbyEnd(1)                       -- finished -> idle
  -- Stated outright rather than inherited: the section above runs on three
  -- lives, where one demolition spends a life instead of deciding anything.
  RM_onDerbySetConfig(1, '{"mode":"dm","lives":1}')

  startDerby(1)
  check(lastDerby.derbyPhase == 'running', 'a derby is running')
  check(lastDerby.derbyOver ~= true, 'and is not decided yet')

  -- Decide it: everyone out but one. That arms the cool-down.
  RM_onDerbyDemolished(2)
  RM_onDerbyDisqualified(3)
  check(lastDerby.derbyOver == true, 'last man standing arms the cool-down')

  -- END IT MID-COOL-DOWN, which is the whole point.
  RM_onDerbyEnd(1)
  check(lastDerby.derbyPhase == 'finished', 'ending during the cool-down finishes it')
  check(lastDerby.derbyOver ~= true,
    'and clears the decided flag rather than leaving it set for ever')

  RM_onDerbyEnd(1)                       -- finished -> idle
  startDerby(1)
  check(lastDerby.derbyPhase == 'running', 'the next derby starts')
  check(lastDerby.derbyOver ~= true,
    'and is NOT born already over -- no stand-down, no handbrake, no stopped '
      .. 'timer counting down on a frozen car')
  RM_onDerbyEnd(1)
  RM_onDerbyEnd(1)
end

print(string.format('derby_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
