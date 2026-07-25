-- Headless test for the league-regulation modules in
-- server/RaceManager/main.lua (Lua 5.3, same as BeamMP):
--   Module 1 - vehicle reset ruleset, DNF + forced spectator on overrun
--   Module 2 - rallycross joker lap: end-of-race validation and the
--              "Disqualified - Missed Joker" line in the results .txt
--   Module 4 - garage list: whitelist capture, spawn/edit enforcement,
--              admin exemption and persistence
-- Run from the repo root: lua5.3 tests/regulations_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState   = nil   -- last RM_Update payload
local lastChat    = nil
local lastDerby   = nil
local spectated   = {}    -- [pid] = last RM_ForceSpectate payload
local released    = {}    -- ordered list of RM_ReleaseSpectate payloads
local rejected    = {}    -- [pid] = last RM_VehicleRejected payload
local garageMsg   = nil   -- last RM_GarageResult payload
local removedVehicles = {}
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
    if event == 'RM_Update'          then lastState = payload end
    if event == 'RM_DerbyUpdate'     then lastDerby = payload end
    if event == 'RM_ForceSpectate'   then spectated[target] = payload end
    if event == 'RM_ReleaseSpectate' then released[#released + 1] = payload end
    if event == 'RM_VehicleRejected' then rejected[target] = payload end
    if event == 'RM_GarageResult'    then garageMsg = payload end
  end,
  RemoveVehicle = function (pid, vid)
    removedVehicles[#removedVehicles + 1] = { pid = pid, vid = vid }
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
local function driver(name)
  for _, d in ipairs(lastState.drivers) do
    if d.name == name then return d end
  end
end
local function adminLogin(pid) RM_onLogin(pid, '{"password":"phoenix"}') end

local RESULTS_DIR = 'Resources/Server/RaceManager/results'
local function readResults()
  local path = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
  if not path then return nil, nil end
  local f = io.open(path, 'r')
  if not f then return nil, path end
  local text = f:read('a')
  f:close()
  return text, path
end

-- Drive a race from a clean slate: grid -> countdown -> GO.
local function startRace(laps)
  RM_onSetTotalLaps(1, '{"laps":' .. laps .. '}')
  RM_onGenerateGrid(1)
  RM_onStartCountdown(1)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

onInit()
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3)

-- ===========================================================================
-- Module 1: vehicle reset ruleset
-- ===========================================================================
RM_onSetMaxResets(1, '{"maxResets":2}')
check(lastState == nil or lastState.maxResets ~= 2,
  'reset limit ignored before authentication')

adminLogin(1)
check(lastState.maxResets == -1, 'resets default to unlimited')

RM_onSetMaxResets(1, '{"maxResets":2}')
check(lastState.maxResets == 2, 'admin sets a reset limit of 2')
RM_onSetMaxResets(1, '{"maxResets":-5}')
check(lastState.maxResets == -1, 'negative limits normalize to unlimited')
RM_onSetMaxResets(1, '{"maxResets":9999}')
check(lastState.maxResets == 99, 'reset limit clamped to the maximum')
RM_onSetMaxResets(1, '{"maxResets":2}')

startRace(3)
check(lastState.phase == 'racing', 'race running with a 2-reset allowance')

-- Resets inside the allowance are just counted.
RM_onVehicleReset(2)
RM_onVehicleReset(2)
check(driver('Bob').resets == 2, 'two resets counted for Bob')
check(spectated[2] == nil, 'Bob is not spectating while inside the allowance')

-- The limit cannot be changed mid-race.
RM_onSetMaxResets(1, '{"maxResets":9}')
check(lastState.maxResets == 2, 'reset limit locked once the race is under way')

-- The client blocked a third reset and reported it: instant DNF + spectator.
lastChat = nil
RM_onResetDenied(2)
check(driver('Bob').status == 'dnf', 'reset overrun is a DNF')
check(driver('Bob').outReason == 'DNF - Reset limit exceeded',
  'DNF reason recorded for the results file')
check(spectated[2] ~= nil and spectated[2].source == 'race',
  'the offender is forced into spectator mode (race-scoped)')
check(type(lastChat) == 'string' and lastChat:find('reset limit exceeded', 1, true),
  'chat announces the reset-limit DNF')
check(lastState.phase == 'racing', 'the race carries on for everyone else')

-- A DNF'd driver cannot keep spending allowance or be punished twice.
RM_onVehicleReset(2)
check(driver('Bob').resets == 2, 'resets stop accruing once the driver is out')
RM_onResetDenied(2)
check(driver('Bob').status == 'dnf', 'duplicate reset-denied reports are no-ops')

-- Reset reports outside a race are ignored entirely.
RM_onEndRace(1)
local beforeIdle = driver('Alice').resets
RM_onVehicleReset(1)
check(driver('Alice').resets == beforeIdle, 'resets outside a race are ignored')
check(#released > 0, 'ending the race releases forced spectators')

-- ===========================================================================
-- Module 2: rallycross joker lap
-- ===========================================================================
RM_onResetLeaderboard(1)
RM_onSetMaxResets(1, '{"maxResets":-1}')
RM_onSetJokerEnabled(1, '{"enabled":true}')
check(lastState.jokerEnabled == true, 'joker lap armed by the admin')

startRace(3)
RM_onSetJokerEnabled(1, '{"enabled":false}')
check(lastState.jokerEnabled == true, 'joker rule locked once the race is under way')

-- Alice takes the joker on lap 2 (legal), Bob takes it twice, Cara never does.
RM_onLap(1, '{"lapTime":60}')   -- everyone completes lap 1
RM_onLap(2, '{"lapTime":61}')
RM_onLap(3, '{"lapTime":62}')
RM_onJokerLap(1, '{"lap":2}')
check(driver('Alice').jokerTaken == 1 and driver('Alice').jokerLap == 2,
  'joker completion recorded with the lap it happened on')
RM_onJokerLap(2, '{"lap":2}')
RM_onJokerLap(2, '{"lap":3}')
check(driver('Bob').jokerTaken == 2, 'a second joker run is counted as a violation')

RM_onLap(1, '{"lapTime":60}'); RM_onLap(2, '{"lapTime":61}'); RM_onLap(3, '{"lapTime":62}')
lastChat = nil
RM_onLap(1, '{"lapTime":59}')   -- Alice finishes (3 laps)
RM_onLap(2, '{"lapTime":60}')   -- Bob finishes
RM_onLap(3, '{"lapTime":61}')   -- Cara finishes -> race closes, ruling applies

check(lastState.phase == 'finished', 'race finished after every driver crossed')
check(driver('Alice').status == 'finished', 'Alice took the joker exactly once and is classified')
check(driver('Cara').status == 'dsq'
  and driver('Cara').outReason == 'Disqualified - Missed Joker',
  'a finisher who never took the joker is disqualified')
check(driver('Bob').status == 'dsq'
  and driver('Bob').outReason == 'Disqualified - Extra Joker',
  'a finisher who took the joker twice is disqualified')
check(lastState.drivers[1].name == 'Alice', 'the only legal finisher is classified P1')
check(lastState.drivers[2].status == 'dsq' and lastState.drivers[3].status == 'dsq',
  'disqualified drivers sort below the classified finisher')

local text, path = readResults()
check(text ~= nil, 'joker race wrote a results file')
if text then
  local raceSec = text:sub(text:find('--- RACE RESULTS ---', 1, true) or 1)
  check(raceSec:match('P1%s+Alice') and raceSec:find('RACE WINNER', 1, true),
    'Alice is the race winner in the results file')
  check(raceSec:match('DSQ%s+Cara%s[^\n]*Disqualified %- Missed Joker'),
    'results .txt records "Disqualified - Missed Joker" for Cara')
  check(raceSec:match('DSQ%s+Bob%s[^\n]*Disqualified %- Extra Joker'),
    'results .txt records the double-joker disqualification for Bob')
  check(text:find('joker lap required exactly once', 1, true),
    'results header states the joker regulation')
  check(raceSec:find('Joker', 1, true), 'results table gains a Joker column when the rule is armed')
end
if path then os.remove(path) end

-- With the rule disarmed the ruling never fires.
RM_onResetLeaderboard(1)
RM_onSetJokerEnabled(1, '{"enabled":false}')
check(lastState.jokerEnabled == false, 'joker lap disarmed')
startRace(1)
lastChat = nil
RM_onLap(1, '{"lapTime":60}'); RM_onLap(2, '{"lapTime":61}'); RM_onLap(3, '{"lapTime":62}')
check(driver('Alice').status == 'finished' and driver('Cara').status == 'finished',
  'nobody is disqualified when the joker rule is off')
local plain, plainPath = readResults()
check(plain and not plain:find('Disqualified', 1, true),
  'a plain race exports no disqualifications')
if plainPath then os.remove(plainPath) end

-- ===========================================================================
-- Module 4: garage list (vehicle & setup locking)
-- ===========================================================================
local SIG_A = 'model=etk800|parts=body=etk800_body;engine=etk800_engine|vars=camber=-1.5000'
local SIG_B = 'model=etk800|parts=body=etk800_body;engine=etk800_engine|vars=camber=-3.0000'

-- Unauthenticated capture attempts are dropped.
RM_onWhitelistVehicle(3, '{"model":"pigeon","label":"Pigeon","sig":"nope"}')
check(lastState.garage == nil or #lastState.garage == 0,
  'whitelist capture requires authentication')

RM_onWhitelistVehicle(1, '{"model":"etk800","label":"ETK 800 - Race","sig":"' .. SIG_A .. '"}')
check(#lastState.garage == 1 and lastState.garage[1].label == 'ETK 800 - Race',
  'admin captured the current vehicle into the Garage List')
check(lastState.garage[1].sig == nil, 'signatures are not broadcast to clients')
check(garageMsg ~= nil and garageMsg.added == true, 'capture confirmed back to the admin')

RM_onWhitelistVehicle(1, '{"model":"etk800","label":"ETK 800 - Race","sig":"' .. SIG_A .. '"}')
check(#lastState.garage == 1, 'capturing the same exact setup twice does not duplicate it')
check(garageMsg.added == false, 'duplicate capture is reported as not added')

-- Enforcement is inert until it is switched on.
rejected = {}; removedVehicles = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"pigeon","sig":"something else"}')
check(rejected[3] == nil, 'nothing is enforced while enforcement is off')

RM_onSetGarageEnforce(1, '{"enabled":true}')
check(lastState.garageEnforce == true, 'enforcement switched on')

-- Exact approved setup: allowed.
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_A .. '"}')
check(rejected[3] == nil, 'the exact approved setup is allowed')

-- Same car, different tune: rejected and deleted.
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_B .. '"}')
check(rejected[3] ~= nil
  and rejected[3].message == 'Vehicle/Setup not allowed in this session.',
  'a non-approved tune of an approved car is rejected with the exact error text')
check(#removedVehicles == 1 and removedVehicles[1].pid == 3 and removedVehicles[1].vid == 7,
  'the offending vehicle is removed from the server')

-- Spawn hook: a model that is not on the list at all is cancelled outright.
rejected = {}; removedVehicles = {}
local cancelled = RM_onVehicleSpawn(3, 12, '5-1{"jbm":"pigeon","vcf":{"parts":{}}}')
check(cancelled == 1, 'spawning an unlisted model is cancelled')
check(rejected[3] ~= nil, 'the spawning player is told why')
check(RM_onVehicleSpawn(3, 13, '5-2{"jbm":"etk800","vcf":{"parts":{}}}') == nil,
  'spawning an approved model passes the model-level check')

-- Editing into an unlisted model is cancelled too.
check(RM_onVehicleEdited(3, 13, '5-2{"jbm":"barstow","vcf":{"parts":{}}}') == 1,
  'editing into an unlisted model is cancelled')

-- Admins are exempt, so they can spawn the car they are about to whitelist.
rejected = {}
check(RM_onVehicleSpawn(1, 20, '1-1{"jbm":"pigeon","vcf":{"parts":{}}}') == nil,
  'authenticated admins bypass the garage check')
RM_onVehicleConfig(1, '{"vid":20,"model":"pigeon","sig":"unknown"}')
check(rejected[1] == nil, 'admin setups are never rejected')

-- Removing the only entry disables enforcement (an empty list must not lock
-- every player out).
rejected = {}
RM_onRemoveGarageEntry(1, '{"index":1}')
check(#lastState.garage == 0, 'garage entry removed')
check(RM_onVehicleSpawn(3, 30, '5-3{"jbm":"pigeon","vcf":{"parts":{}}}') == nil,
  'an empty garage never blocks anyone even with enforcement on')

-- Persistence across a server restart.
RM_onWhitelistVehicle(1, '{"model":"etk800","label":"ETK 800 - Race","sig":"' .. SIG_A .. '"}')
dofile('server/RaceManager/main.lua')
onInit()
RM_onRequestState(1)
check(#lastState.garage == 1 and lastState.garage[1].label == 'ETK 800 - Race',
  'the Garage List survives a server restart via garage.json')
check(lastState.garageEnforce == true, 'the enforcement switch persists too')
adminLogin(1)
RM_onClearGarage(1)
check(#lastState.garage == 0, 'Clear Garage empties the list')

-- ===========================================================================
-- Demo Derby isolation: elimination forces spectator mode via the derby's own
-- source, and the derby never touches the racing state machine.
-- ===========================================================================
spectated = {}; released = {}
RM_onDerbyStart(1)
RM_onDerbyDemolished(2)
check(spectated[2] ~= nil and spectated[2].source == 'derby',
  'a derby elimination forces spectator mode scoped to the derby')
RM_onDerbyDisqualified(3)  -- last man standing ends the derby
check(lastDerby.derbyPhase == 'finished', 'derby ended with a winner')
local sawDerbyRelease = false
for _, r in ipairs(released) do
  if r.source == 'derby' then sawDerbyRelease = true end
end
check(sawDerbyRelease, 'finishing the derby releases only the derby spectators')

-- Clean up the directory tree this test created in the repo root
os.execute('rm -rf Resources')

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
