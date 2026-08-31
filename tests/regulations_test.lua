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

local RESULTS_DIR = 'Resources/Server/RaceManager/Data/results'
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
-- This suite predates the entry list; run it with entry open to everyone.
adminLogin(1)
RM_onLogout(1)
lastState = nil

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

-- Reset mode: in place (default) or respawn at the last checkpoint crossed.
check(lastState.resetMode == 'inplace', 'reset mode defaults to in place')
RM_onSetResetMode(1, '{"mode":"checkpoint"}')
check(lastState.resetMode == 'checkpoint', 'reset mode switches to last checkpoint')
RM_onSetResetMode(1, '{"mode":"sideways"}')
check(lastState.resetMode == 'checkpoint', 'an unknown reset mode is rejected')
RM_onSetResetMode(1, '{"mode":"inplace"}')
check(lastState.resetMode == 'inplace', 'and back to in place')

startRace(3)
check(lastState.phase == 'racing', 'race running with a 2-reset allowance')

-- The mode is locked once the race is under way, like every regulation.
RM_onSetResetMode(1, '{"mode":"checkpoint"}')
check(lastState.resetMode == 'inplace', 'reset mode locked once the race is under way')

-- Resets inside the allowance are just counted.
RM_onVehicleReset(2)
RM_onVehicleReset(2)
check(driver('Bob').resets == 2, 'two resets counted for Bob')
check(spectated[2] == nil, 'Bob is not spectating while inside the allowance')

-- The limit cannot be changed mid-race.
RM_onSetMaxResets(1, '{"maxResets":9}')
check(lastState.maxResets == 2, 'reset limit locked once the race is under way')

-- The client BLOCKED a third reset (it put the car back where it was) and
-- reported the attempt. That is not a penalty: Bob keeps racing, keeps his car
-- and stays out of spectator mode - the attempt is only counted.
lastChat = nil
RM_onResetDenied(2)
check(driver('Bob').status == 'racing', 'a blocked reset does not end the race')
check(driver('Bob').outReason == nil, 'no DNF reason is recorded for a blocked reset')
check(driver('Bob').resetsBlocked == 1, 'the blocked attempt is counted')
check(driver('Bob').resets == 2, 'a blocked reset does not spend allowance')
check(spectated[2] == nil, 'a blocked reset never forces spectator mode')
check(lastState.phase == 'racing', 'the race carries on')

-- Repeated attempts keep counting; the driver is never punished for them.
RM_onResetDenied(2)
check(driver('Bob').resetsBlocked == 2, 'further blocked attempts keep counting')
check(driver('Bob').status == 'racing', 'still racing after a second blocked reset')

-- A rogue over-allowance RM_VehicleReset report cannot push the tally past the
-- limit: it is recorded as one more blocked attempt instead, so the counter
-- can never render as "3/2".
RM_onVehicleReset(2)
check(driver('Bob').resets == 2, 'the used-reset tally can never pass the limit')
check(driver('Bob').resetsBlocked == 3, 'the over-limit report counts as blocked instead')

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

-- THE TRACK HAS TO HAVE A JOKER ROUTE FIRST.
--
-- The rule reclassifies anyone who did not complete the joker exactly once, so
-- arming it on a track with no joker gates disqualifies every driver who
-- finishes -- for missing a route that does not exist, with nothing saying why
-- until the results file is written. The server refuses it outright.
RM_onSetJokerEnabled(1, '{"enabled":true}')
check(lastState.jokerEnabled == false,
  'the joker lap cannot be armed on a track with no joker gates')

-- Tell the server the track has them, as a client with a joker route placed does.
RM_onStartPositionCount(1, '{"count":0,"positions":[],"jokerGates":3}')
RM_onSetJokerEnabled(1, '{"enabled":true}')
check(lastState.jokerEnabled == true, 'joker lap armed by the admin')
check(lastState.jokerGates == 3, 'the panel is told how many gates the track has')

-- Clearing the route while the rule is armed disarms it rather than leaving a
-- race pointed at a disqualification nobody can avoid.
RM_onStartPositionCount(1, '{"count":0,"positions":[],"jokerGates":0}')
check(lastState.jokerEnabled == false,
  'clearing the joker route switches the rule back off')
RM_onStartPositionCount(1, '{"count":0,"positions":[],"jokerGates":3}')
RM_onSetJokerEnabled(1, '{"enabled":true}')
check(lastState.jokerEnabled == true, 'and it can be armed again once gates are back')

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

-- Past the hold at the flag: a race no longer closes on the tick the last car
-- crosses, so the field stays ghosted for a moment (see race.endDelay).
for _ = 1, 70 do RM_Tick() end
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
  check(raceSec:match('P1%s+%S+%s+Alice') and raceSec:find('RACE WINNER', 1, true),
    'Alice is the race winner in the results file')
  check(raceSec:match('DSQ%s+%S+%s+Cara%s[^\n]*Disqualified %- Missed Joker'),
    'results .txt records "Disqualified - Missed Joker" for Cara')
  check(raceSec:match('DSQ%s+%S+%s+Bob%s[^\n]*Disqualified %- Extra Joker'),
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
-- Past the hold at the flag: a race no longer closes on the tick the last car
-- crosses, so results are written a moment later (see race.endDelay).
for _ = 1, 70 do RM_Tick() end
local plain, plainPath = readResults()
check(plain and not plain:find('Disqualified', 1, true),
  'a plain race exports no disqualifications')
if plainPath then os.remove(plainPath) end

-- ===========================================================================
-- Module 4: garage list (vehicle & setup locking)
-- ===========================================================================
local SIG_A = 'model=etk800|parts=body=etk800_body;engine=etk800_engine|vars=camber=-1.5000'
local SIG_B = 'model=etk800|parts=body=etk800_body;engine=etk800_engine|vars=camber=-3.0000'

-- START FROM A KNOWN GARAGE. This section persists to garage.json by design, so
-- a run that dies partway leaves entries behind and the next run fails its first
-- four checks for reasons that have nothing to do with the code being tested.
os.remove('Resources/Server/RaceManager/Data/garage.json')
dofile('server/RaceManager/main.lua')
onInit()
adminLogin(1)

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

-- ---------------------------------------------------------------------------
-- Parts mode (the default): the parts are the rule, the tune is not
-- ---------------------------------------------------------------------------
-- SIG_A and SIG_B are the same car with the same parts on a different camber
-- setting. That is a legal setup change in a spec series and an illegal one in
-- a one-make cup, which is the whole reason the mode exists.
rejected = {}
check(lastState.garageMode == 'parts', 'parts is the default enforcement mode')
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_B .. '"}')
check(rejected[3] == nil, 'in parts mode a re-tune of an approved car is allowed')

-- The parts half is recovered from a one-signature (pre-split) client, so an
-- older client is not locked out of a mode it knows nothing about.
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","partsSig":'
  .. '"model=etk800|parts=body=etk800_body;engine=etk800_engine","sig":"' .. SIG_B .. '"}')
check(rejected[3] == nil, 'a client sending both signatures matches on the parts half')

-- Swap a part and it is refused, tune or no tune.
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800",'
  .. '"sig":"model=etk800|parts=body=etk800_body;engine=v8_swap|vars=camber=-1.5000"}')
check(rejected[3] ~= nil
  and rejected[3].message == 'Vehicle/Setup not allowed in this session.',
  'a part swap on an approved car is rejected with the exact error text')
check(rejected[3].detail:find('Parts', 1, true),
  'and the refusal names the mode, so the driver knows what to undo')
check(rejected[3].remove == true, 'the client is ordered to delete the car')
check(#removedVehicles == 0,
  'MP.RemoveVehicle is NOT called on the config path: the id there is a BeamNG '
  .. 'game object id, not a BeamMP one, so the client is the one that deletes it')

-- ---------------------------------------------------------------------------
-- Strict mode: the tune is the rule as well
-- ---------------------------------------------------------------------------
RM_onSetGarageMode(1, '{"mode":"strict"}')
check(lastState.garageMode == 'strict', 'enforcement mode switched to strict')
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_A .. '"}')
check(rejected[3] == nil, 'the exact captured tune is still allowed in strict mode')
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_B .. '"}')
check(rejected[3] ~= nil, 'the same parts on a different tune are refused in strict mode')
check(rejected[3].detail:find('Strict', 1, true), 'and the refusal names strict mode')

RM_onSetGarageMode(1, '{"mode":"nonsense"}')
check(lastState.garageMode == 'strict', 'an unrecognized mode is refused, not applied')
RM_onSetGarageMode(3, '{"mode":"parts"}')
check(lastState.garageMode == 'strict', 'setting the mode requires authentication')
RM_onSetGarageMode(1, '{"mode":"parts"}')
check(lastState.garageMode == 'parts', 'and back to parts')

-- Spawn hook: a model that is not on the list at all is canceled outright.
rejected = {}; removedVehicles = {}
local canceled = RM_onVehicleSpawn(3, 12, '5-1{"jbm":"pigeon","vcf":{"parts":{}}}')
check(canceled == 1, 'spawning an unlisted model is canceled')
check(rejected[3] ~= nil, 'the spawning player is told why')
check(RM_onVehicleSpawn(3, 13, '5-2{"jbm":"etk800","vcf":{"parts":{}}}') == nil,
  'spawning an approved model passes the model-level check')

-- Editing into an unlisted model is canceled too.
check(RM_onVehicleEdited(3, 13, '5-2{"jbm":"barstow","vcf":{"parts":{}}}') == 1,
  'editing into an unlisted model is canceled')

-- NOBODY IS EXEMPT, admins included. This reverses how the split first shipped:
-- an admin used to be told and listed but keep the car. Building the list is
-- done with Enforcing switched off instead, and an empty list never enforces
-- anything, so neither of the cases the exemption existed for needs it.
rejected = {}
check(RM_onVehicleSpawn(1, 20, '1-1{"jbm":"pigeon","vcf":{"parts":{}}}') == 1,
  'an admin spawning an unlisted model is canceled like anyone else')
rejected = {}; removedVehicles = {}
RM_onVehicleConfig(1, '{"vid":20,"model":"pigeon","sig":"model=pigeon|parts=body=x|vars="}')
check(rejected[1] ~= nil, 'an admin in an unapproved car is refused')
check(rejected[1].remove == true, 'and is ordered to delete it, exactly like a driver')
-- Put the admin back in something legal so the later grid audit is about the
-- driver under test and not about this.
RM_onVehicleConfig(1, '{"vid":20,"model":"etk800","sig":"' .. SIG_A .. '"}')

-- ---------------------------------------------------------------------------
-- A signature with no parts in it is never ruled on
-- ---------------------------------------------------------------------------
-- THE BUG THAT REFUSED THE CAR THE LIST WAS BUILT FROM. onVehicleSpawned used
-- to report on the frame the vehicle object appeared, before BeamNG had loaded
-- its parts, so the client sent 'model=X|parts=' - which matches no entry on any
-- list. That cost nothing while the deletion was broken and deleted the car the
-- moment it started working.
rejected = {}; removedVehicles = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"model=etk800|parts=|vars="}')
check(rejected[3] == nil,
  'a report with an empty part list is ignored, not refused')
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","partsSig":"model=etk800|parts=",'
  .. '"sig":"model=etk800|parts=|vars=camber=-1.5000"}')
check(rejected[3] == nil, 'and the same when the client sends both signatures')

-- The standing verdict survives it: "ask again in a moment" must not blank a
-- ruling the panel is already showing.
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800",'
  .. '"sig":"model=etk800|parts=body=etk800_body;engine=v8_swap|vars=camber=-1.5000"}')
RM_onGenerateGrid(1)
garageMsg = nil
RM_onStartCountdown(1)
check(garageMsg ~= nil and garageMsg.message:find('Cara', 1, true), 'the offender is listed')
RM_onEndRace(1)
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"model=etk800|parts=|vars="}')
RM_onGenerateGrid(1)
garageMsg = nil
RM_onStartCountdown(1)
check(garageMsg ~= nil and garageMsg.message:find('Cara', 1, true),
  'and an empty report afterwards leaves that ruling standing')
RM_onEndRace(1)

-- ---------------------------------------------------------------------------
-- The model is matched on the bare jbeam name
-- ---------------------------------------------------------------------------
-- The list stores whatever veh:getJBeamFilename() returned and the spawn packet
-- carries "jbm". Nothing promises those agree on case, on a leading path or on
-- the extension, and a disagreement refuses a car that is plainly listed.
rejected = {}
RM_onWhitelistVehicle(1, '{"model":"/vehicles/covet/covet.jbeam","label":"Covet - Path",'
  .. '"sig":"model=covet|parts=body=covet_body|vars="}')
check(RM_onVehicleSpawn(3, 41, '5-4{"jbm":"covet","vcf":{"parts":{}}}') == nil,
  'a path-and-extension model on the list matches a bare jbm on the packet')
check(RM_onVehicleSpawn(3, 42, '5-5{"jbm":"COVET","vcf":{"parts":{}}}') == nil,
  'and the comparison ignores case')
RM_onRemoveGarageEntry(1, '{"index":2}')

-- ---------------------------------------------------------------------------
-- A Garage List captured before a BeamNG update that renamed vehicle parts
-- ---------------------------------------------------------------------------
-- BeamNG v0.39 renamed parts on several vehicles. The car has not changed, but
-- its configuration signature has, so every entry captured on an older build
-- stops matching and drivers get rejected in a car that is plainly on the list.
-- Nothing on the server can repair that (only a re-capture can), so the
-- rejection has to name the cause.
rejected = {}; removedVehicles = {}
local SUN_OLD = 'model=sunburst|parts=body=sunburst_body;engine=sunburst_engine|vars='
local SUN_NEW = 'model=sunburst|parts=body=sunburst_bodyshell;engine=sunburst_i4|vars='
RM_onWhitelistVehicle(1,
  '{"model":"sunburst","label":"Sunburst - Cup","sig":"' .. SUN_OLD .. '","game":"0.38"}')
check(#lastState.garage == 2, 'a capture carrying a game version is stored')

-- Same model, signature built from the renamed parts, driver on the new build.
RM_onVehicleConfig(3, '{"vid":9,"model":"sunburst","sig":"' .. SUN_NEW .. '","game":"0.39"}')
check(rejected[3] ~= nil, 'a signature built from renamed parts is still rejected')
check(rejected[3].detail:find('0.38', 1, true)
  and rejected[3].detail:find('0.39', 1, true)
  and rejected[3].detail:find('re%-capture'),
  'and the rejection names both builds and the fix (re-capture the list)')
check(rejected[3].message == 'Vehicle/Setup not allowed in this session.',
  'the driver-facing message is unchanged')

-- Same build on both sides: an ordinary "that car is not allowed" rejection.
-- Asserted as "does not blame the game version" rather than on the exact
-- sentence, because the plain wording names the enforcement mode now and that
-- text is meant to be free to improve.
rejected = {}
RM_onVehicleConfig(3, '{"vid":9,"model":"sunburst","sig":"' .. SUN_NEW .. '","game":"0.38"}')
check(rejected[3] ~= nil and not rejected[3].detail:find('re%-capture'),
  'a mismatch on the same build keeps the plain wording')
check(rejected[3].detail:find('Parts', 1, true), 'and names the mode in force')

-- Entries captured before the version was recorded at all are never blamed on
-- a version skew. A PART SWAP, not a re-tune: in parts mode a re-tune is legal,
-- so it would never reach a rejection to check the wording of.
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","game":"0.39",'
  .. '"sig":"model=etk800|parts=body=etk800_body;engine=v8_swap|vars=camber=-1.5000"}')
check(rejected[3] ~= nil and not rejected[3].detail:find('re%-capture'),
  'an entry with no recorded build is never reported as a version skew')

RM_onRemoveGarageEntry(1, '{"index":2}')
check(#lastState.garage == 1, 'the versioned entry removed again')

-- ---------------------------------------------------------------------------
-- The broadcast view of the Garage List is cached
-- ---------------------------------------------------------------------------
-- It is rebuilt into every state broadcast, which is a table per approved car
-- three times a second for the life of the server -- describing a list an admin
-- touches perhaps twice a session. So it is built once and held.
--
-- Caching it moves the risk from "wasteful" to "wrong": a view that does not
-- notice a capture shows drivers a Garage List the server is no longer
-- enforcing. Invalidation is one rule -- saveGarageToDisk, which every mutation
-- already goes through -- and these checks are what say that rule is actually
-- being applied on each of the four paths that can change it.
local viewBefore = lastState.garage
RM_onRequestState(1)
check(lastState.garage == viewBefore,
  'a broadcast that changes nothing reuses the same list, it does not rebuild it')
RM_onPlayerJoin(2)
check(lastState.garage == viewBefore, 'and it survives other traffic untouched')

-- Capture: the view has to change, and say the right thing.
RM_onWhitelistVehicle(1, '{"model":"covet","label":"Covet - Track","sig":"covetsig"}')
check(lastState.garage ~= viewBefore, 'a capture rebuilds the view')
check(#lastState.garage == 2 and lastState.garage[2].label == 'Covet - Track',
  'and the captured car is in it')

-- Enforcement flag: same list, but the flag beside it moved.
viewBefore = lastState.garage
RM_onSetGarageEnforce(1, '{"enabled":false}')
check(lastState.garageEnforce == false, 'enforcement switched off')
check(lastState.garage ~= viewBefore, 'flipping enforcement rebuilds the view too')
RM_onSetGarageEnforce(1, '{"enabled":true}')

-- Removal.
viewBefore = lastState.garage
RM_onRemoveGarageEntry(1, '{"index":2}')
check(lastState.garage ~= viewBefore, 'removing an entry rebuilds the view')
check(#lastState.garage == 1, 'and it is gone from the list clients see')

-- Clearing.
viewBefore = lastState.garage
RM_onClearGarage(1)
check(lastState.garage ~= viewBefore, 'clearing the garage rebuilds the view')
check(#lastState.garage == 0, 'and leaves nothing in it')

-- Removing the only entry disables enforcement (an empty list must not lock
-- every player out).
rejected = {}
RM_onRemoveGarageEntry(1, '{"index":1}')
check(#lastState.garage == 0, 'garage entry removed')
check(RM_onVehicleSpawn(3, 30, '5-3{"jbm":"pigeon","vcf":{"parts":{}}}') == nil,
  'an empty garage never blocks anyone even with enforcement on')

-- ---------------------------------------------------------------------------
-- The grid audit: who starts a race in a car the list does not cover
-- ---------------------------------------------------------------------------
-- Reports and does not act. The live check has already taken the car off any
-- non-admin, so anyone still listed at the lights is a case it could not act
-- on, and pulling a car off the grid during the countdown is worse for the race
-- than starting with one wrong setup in it.
RM_onWhitelistVehicle(1, '{"model":"etk800","label":"ETK 800 - Race","sig":"' .. SIG_A .. '"}')
RM_onSetGarageEnforce(1, '{"enabled":true}')
rejected = {}; garageMsg = nil; removedVehicles = {}
RM_onVehicleConfig(2, '{"vid":8,"model":"etk800","label":"ETK 800 - Illegal",'
  .. '"sig":"model=etk800|parts=body=etk800_body;engine=v8_swap|vars=camber=-1.5000"}')
check(rejected[2] ~= nil, 'the offender was told at the moment they declared')
RM_onGenerateGrid(1)
garageMsg = nil
RM_onStartCountdown(1)
check(garageMsg ~= nil and garageMsg.message:find('Garage List', 1, true),
  'Start Countdown reports the non-compliant grid to the admin who pressed it')
check(garageMsg.message:find('Bob', 1, true), 'and names the driver')
check(lastState.phase == 'countdown', 'and starts the race anyway: it reports, it does not block')
RM_onEndRace(1)

-- ---------------------------------------------------------------------------
-- Changing the list re-judges the field
-- ---------------------------------------------------------------------------
-- Clients only re-declare when their OWN car changes, so an admin who adds the
-- entry that legalises somebody would otherwise leave them marked as an
-- offender until they next happened to touch their setup. The verdicts are
-- re-derived from the signatures already on record whenever the list moves.
local SIG_SWAP = 'model=etk800|parts=body=etk800_body;engine=v8_swap|vars=camber=-1.5000'
rejected = {}
RM_onVehicleConfig(2, '{"vid":8,"model":"etk800","sig":"' .. SIG_SWAP .. '"}')
check(rejected[2] ~= nil, 'the swapped car is refused against the list as it stands')
RM_onWhitelistVehicle(1, '{"model":"etk800","label":"ETK 800 - V8","sig":"' .. SIG_SWAP .. '"}')
garageMsg = nil
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
check(garageMsg == nil,
  'capturing the car clears the driver without them re-declaring anything')
RM_onEndRace(1)

-- ...and the same in reverse: dropping the entry puts the mark back.
RM_onRemoveGarageEntry(1, '{"index":2}')
garageMsg = nil
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
check(garageMsg ~= nil and garageMsg.message:find('Bob', 1, true),
  'and removing it again marks them without them re-declaring either')
RM_onEndRace(1)

-- Switching the mode re-judges too: strict disagrees with parts about who is
-- legal, and the verdicts have to follow the rule actually in force.
RM_onVehicleConfig(2, '{"vid":8,"model":"etk800","sig":"' .. SIG_B .. '"}')
RM_onSetGarageMode(1, '{"mode":"strict"}')
garageMsg = nil
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
check(garageMsg ~= nil and garageMsg.message:find('Bob', 1, true),
  'a re-tune legal under parts is marked the moment strict is switched on')
RM_onEndRace(1)
RM_onSetGarageMode(1, '{"mode":"parts"}')
garageMsg = nil
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
-- Bob specifically, not "the audit is empty": Cara is still carrying the
-- part-swapped signature she declared back in the version-skew section, and
-- that is illegal under BOTH modes. An assertion that the whole audit went
-- quiet would be testing the fixture rather than the re-judge.
check(garageMsg == nil or not garageMsg.message:find('Bob', 1, true),
  'and unmarked again on the way back')
RM_onEndRace(1)

-- A driver who has declared nothing is not an offender. "Hasn't reported yet"
-- and "is cheating" are different states and only one of them is red.
-- Everyone who declared an illegal setup earlier in this file is still carrying
-- that verdict, which is the feature working. Put the whole field in something
-- legal so the check below is about the empty case and not about them.
rejected = {}; garageMsg = nil
RM_onVehicleConfig(2, '{"vid":8,"model":"etk800","sig":"' .. SIG_A .. '"}')
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_A .. '"}')
RM_onGenerateGrid(1)
garageMsg = nil
RM_onStartCountdown(1)
check(garageMsg == nil, 'a compliant grid produces no audit line at all')
RM_onEndRace(1)

-- Persistence across a server restart.
RM_onSetGarageMode(1, '{"mode":"strict"}')
dofile('server/RaceManager/main.lua')
onInit()
RM_onRequestState(1)
check(#lastState.garage == 1 and lastState.garage[1].label == 'ETK 800 - Race',
  'the Garage List survives a server restart via garage.json')
check(lastState.garageEnforce == true, 'the enforcement switch persists too')
check(lastState.garageMode == 'strict', 'and so does the enforcement mode')

-- A garage.json written before parts and tuning were split has no `mode` and no
-- per-entry `partsSig`. It must load, default to the LOOSER mode, and recover
-- the parts half from the full signature rather than demanding a re-capture:
-- an upgrade that silently starts rejecting legal tunes is worse than useless.
local legacy = io.open('Resources/Server/RaceManager/Data/garage.json', 'w')
legacy:write('{"version":1,"enforce":true,"list":[{"model":"etk800",'
  .. '"label":"ETK 800 - Legacy","sig":"' .. SIG_A .. '"}]}')
legacy:close()
dofile('server/RaceManager/main.lua')
onInit()
adminLogin(1)
RM_onRequestState(1)
check(lastState.garageMode == 'parts', 'a pre-split garage.json loads in parts mode')
check(#lastState.garage == 1 and lastState.garage[1].label == 'ETK 800 - Legacy',
  'and its entries load')
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_B .. '"}')
check(rejected[3] == nil,
  'the parts half was derived from the old signature: a re-tune matches with no re-capture')
rejected = {}
RM_onVehicleConfig(3, '{"vid":7,"model":"etk800","sig":"' .. SIG_A .. '"}')
check(rejected[3] == nil, 'and the exact captured setup still matches')

RM_onClearGarage(1)
check(#lastState.garage == 0, 'Clear Garage empties the list')

-- ===========================================================================
-- Demo Derby isolation: elimination forces spectator mode via the derby's own
-- source, and the derby never touches the racing state machine.
-- ===========================================================================
spectated = {}; released = {}
-- A derby starts in two steps now: Form Up places and holds the field, then
-- Start Derby releases it with a countdown. Nothing is eliminated before GO.
RM_onDerbyFormUp(1)
RM_onDerbyStart(1)
for _ = 1, 3 do RM_DerbyCountdownTick() end
RM_onDerbyDemolished(2)
check(spectated[2] ~= nil and spectated[2].source == 'derby',
  'a derby elimination forces spectator mode scoped to the derby')
RM_onDerbyDisqualified(3)  -- last man standing decides the derby
-- ...which does not end it on the instant: the arena stays up for a short
-- cool-down so the result can be seen among the wrecks.
for _ = 1, 6 do RM_DerbyTick() end
check(lastDerby.derbyPhase == 'finished', 'derby ended with a winner')
local sawDerbyRelease = false
for _, r in ipairs(released) do
  if r.source == 'derby' then sawDerbyRelease = true end
end
check(sawDerbyRelease, 'finishing the derby releases only the derby spectators')

-- Clean up the directory tree this test created in the repo root. "rm -rf" is
-- not a command on Windows, so the tree has to be removed the native way there.
if package.config:sub(1, 1) == '\\' then
  os.execute('rmdir /s /q "Resources" 2>nul')
else
  os.execute('rm -rf Resources')
end

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
