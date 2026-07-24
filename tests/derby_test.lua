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
local lastChat = nil
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
    if event == 'RM_Update'      then lastState = payload end
    if event == 'RM_DerbyUpdate' then lastDerby = payload end
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
local function derbyPlayer(name)
  for _, p in ipairs(lastDerby.players) do
    if p.name == name then return p end
  end
end

onInit()

-- Derby admin events now require authentication too. Confirm an unauthenticated
-- session is rejected, then log in the admin sessions the suite drives with.
RM_onDerbyStart(1)
check(lastDerby == nil, 'derby start ignored before authentication')
RM_onLogin(1, '{"password":"phoenix"}')
RM_onLogin(2, '{"password":"phoenix"}')

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
RM_onDerbyStart(1)
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

-- Last man standing: derby self-ends, Alice wins.
check(lastDerby.derbyPhase == 'finished', 'derby finished when one remains')
check(derbyPlayer('Alice').status == 'winner', 'Alice is the winner')
check(lastDerby.winner == 'Alice', 'winner broadcast')
check(timers['RM_DerbyTick'] == nil, 'derby tick timer cancelled')
check(type(lastChat) == 'string' and lastChat:find('WINNER: Alice', 1, true),
  'chat announces the winner')

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
RM_onDerbyStart(2)
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
RM_onDerbyStart(1)
for _ = 1, 3 do RM_DerbyTick() end
RM_Derby_onPlayerDisconnect(3)
check(derbyPlayer('Cara').status == 'eliminated'
  and derbyPlayer('Cara').reason == 'Disqualified', 'disconnect counts as disqualified')
check(lastDerby.derbyPhase == 'running', 'derby continues with two alive')
RM_onDerbyDemolished(1)
check(lastDerby.derbyPhase == 'finished' and lastDerby.winner == 'Bob',
  'Bob wins the third derby')
local p3 = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
if p3 then os.remove(p3) end

-- ---------------------------------------------------------------------------
-- Isolation: the whole derby session never touched circuit racing state
-- ---------------------------------------------------------------------------
check(lastState == nil, 'no RM_Update was ever broadcast by derby activity')
RM_onRequestState(1)
check(lastState.phase == 'waiting', 'racing state machine still waiting')
check(lastState.totalLaps == 5, 'race distance untouched by the derby')

print(string.format('derby_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
