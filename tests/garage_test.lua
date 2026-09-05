-- Headless test for THE GARAGE LIST's client half: reading the car's part
-- configuration, and the Whitelist Current Vehicle button that sends it.
-- Run from the repo root: lua tests/garage_test.lua
--
-- WHY THIS FILE DID NOT EXIST, AND WHAT THAT COST.
--
-- Every other harness in this repo stubs the part manager the same way:
--
--     core_vehicle_partmgmt = { getConfig = function ()
--       return { parts = {}, vars = {} }
--     end }
--
-- Eighteen of them, and the parts table is EMPTY in all eighteen. The client
-- reads an empty parts list as "this car has not finished loading", which is the
-- right reading at spawn -- no BeamNG vehicle has zero parts -- so under every
-- test in the repo localVehicleConfig() returns nil and the entire Garage List
-- path stops at its first guard. The success case had never been executed.
--
-- That mattered twice over, because the refusal was also INVISIBLE: it is
-- written to `editorMsg`, which was rendered only in the track editor, and the
-- button lives on the Garage tab. So the feature could fail on every press, in
-- every session, and produce neither a failing test nor a visible symptom. It
-- was reported as a dead button.
--
-- This file drives the part list from the test, so both answers can be asked
-- for: a car that reports its parts, and a car that does not.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local VEH_ID = 7

-- What each configuration source will answer this time round. Set per case.
local partmgmtConfig   = nil     -- core_vehicle_partmgmt.getConfig()
local vehicleDataConfig = nil    -- core_vehicle_manager.getVehicleData().config
local partmgmtPresent   = true
local vehicleManagerPresent = true

local veh = { id = VEH_ID, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
local primed = false
local queued = {}
function veh:queueLuaCommand(cmd)
  queued[#queued + 1] = tostring(cmd)
  if tostring(cmd):find('partmgmt', 1, true) then primed = true end
end
function veh:setMeshAlpha() end
-- The vehicle object's own build identity. BeamMP spawns a car by applying a
-- config, and the vehicle VM never ends up holding the parts -- but this field
-- still names the build, which is what a garage entry needs.
local partConfigField = nil
function veh:getField(name)
  if name == 'partConfig' then return partConfigField end
  return nil
end

getPlayerVehicle = function () return veh end
be = { getPlayerVehicle = function () return veh end }
getAllVehicles = function () return { veh } end
getObjectByID = function (id) return id == VEH_ID and veh or nil end
MPVehicleGE = { isOwn = function (id) return id == VEH_ID end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'

-- The two sources, each switchable off entirely so the "no source at all" case
-- can be reached: a build that exposes neither must not be told to try again.
core_vehicle_partmgmt = setmetatable({}, { __index = function (_, k)
  if k == 'getConfig' and partmgmtPresent then
    return function () return partmgmtConfig end
  end
  return nil
end })
core_vehicle_manager = setmetatable({}, { __index = function (_, k)
  if k == 'getVehicleData' and vehicleManagerPresent then
    return function (id)
      if id ~= VEH_ID then return nil end
      return { config = vehicleDataConfig }
    end
  end
  return nil
end })

local V = {}
V.__index = V
V.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__mul = function (a, s) return setmetatable({ x = a.x * s, y = a.y * s, z = a.z * s }, V) end
vec3 = function (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end, drawTextAdvanced = function () end,
  drawQuadSolid = function () end, drawTriSolid = function () end,
  drawSphere = function () end, drawLine = function () end,
}
MPGameNetwork = {}
MPConfig = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function readFile(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local t = f:read('*a')
  f:close()
  return t
end

local function clearLog() sent, hooks = {}, {} end
-- Burn the probe cooldown, which is FIFTEEN seconds: the car is asked in its own
-- Lua state, and that state runs on the physics thread, so asking often is a
-- stall the driver feels. A test pressing the button twice in the same instant
-- therefore sees only the first ask, exactly as a human hammering it would.
local function advance(seconds)
  for _ = 1, math.ceil((seconds or 20) / 0.1) do RM.onUpdate(0.1) end
end
-- Let the signature SETTLE, then capture.
--
-- Nothing is judged on a signature until it has come out the same several polls
-- running: the parts, the tuning and BeamMP's record all read empty for a
-- moment after a car appears, and any one of those empty-to-real transitions is
-- a second signature for a car nobody has touched -- which the server refuses
-- and deletes. So a test that changes something and captures in the same breath
-- is testing a state no client is ever judged in.
local function settle()
  advance(8)
end

local function whitelisted()
  for _, x in ipairs(sent) do
    if x.event == 'RM_WhitelistVehicle' then return x.payload end
  end
  return nil
end
-- The refusal, as the admin panel receives it.
local function refusal()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerEditorMsg' then
      return hooks[i].payload and hooks[i].payload.msg
    end
  end
  return nil
end

-- Give the car a new spawn config, the only way a real one ever gets one: by
-- being REBUILT. `partConfig` is read once per car and cached, because on an
-- edited car it is tens of kilobytes and hashing it on every poll is what made
-- the game freeze -- so a test that changes it without a rebuild is testing
-- something no client can do.
local function respawnWith(pc, pd, vd)
  partConfigField = pc
  RM.onVehicleSpawned(VEH_ID)
  advance(20)
  RM.onVehicleDigest(pd or '0:0:0:0', vd or '0:0:0:0')
end

-- A spawn configuration in the shape the game actually writes, with whichever
-- parts the case needs. Used wherever a test needs a car whose parts can be
-- READ: '0:0:0:0' is the digest of nothing, no real car has no parts, and a
-- car whose parts cannot be read is no longer declared at all.
local function treeConfig(parts)
  local bits = {}
  for slot, part in pairs(parts) do
    bits[#bits + 1] = '["' .. slot .. '"]={["chosenPartName"]="' .. part
      .. '",["children"]={}}'
  end
  table.sort(bits)
  return '{["partsTree"]={["chosenPartName"]="legran",["children"]={'
    .. table.concat(bits, ',') .. '}}}'
end

-- A configuration that looks like a real one: a car has parts.
local function realConfig(name)
  return {
    parts = { body = 'etk800_body', engine = 'etk800_engine_i6' },
    vars  = { ['$tirepressure_R'] = 30 },
    configName = name,
  }
end

-- ---------------------------------------------------------------------------
-- 1. THE CASE NO TEST HAS EVER RUN: a car that reports its parts
-- ---------------------------------------------------------------------------
partmgmtConfig, vehicleDataConfig = realConfig('Stock'), nil
settle()
clearLog()
RM.whitelistCurrentVehicle()
local p = whitelisted()
check(p ~= nil,
  'a car with a part list is actually sent to the server: this is the whole '
    .. 'feature, and no test in the repo had executed it')
check(p and p.sig and p.sig ~= '',
  'and it carries a configuration signature, which is what the server files it '
    .. 'under (an empty one is refused there)')
check(p and p.partsSig and p.partsSig ~= '',
  'and the parts half of it, so a Parts-mode league matches on the parts alone')
check(p and p.sig ~= p.partsSig,
  'the two halves are different: strict adds the tuning vars on top of parts')
check(p and p.model == 'etk800', 'the model rides along for the label')
check(p and p.label and p.label:find('Stock', 1, true) ~= nil,
  'and the config name reaches the label, so the list is readable')

-- ---------------------------------------------------------------------------
-- 2. THE REPORTED BUG: the part manager cannot see this car
-- ---------------------------------------------------------------------------
-- getConfig() reads whichever vehicle the PART MANAGER considers current, which
-- is not always the car the player is driving. When it answers with nothing
-- there is no way to tell that apart from a half-loaded car: both are an empty
-- table. The button refused with "still loading" every time, forever, and the
-- message had nowhere to appear.
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, realConfig('Stock')
settle()
clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() ~= nil,
  'when the part manager answers empty, the per-vehicle store is asked and the '
    .. 'car is whitelisted anyway')

-- ...and the first source still wins when it CAN answer, so nothing regresses
-- where this already worked.
partmgmtConfig  = realConfig('FromPartMgmt')
vehicleDataConfig = realConfig('FromVehicleData')
settle()
clearLog()
RM.whitelistCurrentVehicle()
p = whitelisted()
check(p and p.label:find('FromPartMgmt', 1, true) ~= nil,
  'the part manager is still asked FIRST: where it works it is authoritative')

-- ---------------------------------------------------------------------------
-- 3. A GENUINELY HALF-LOADED CAR still refuses, and says so
-- ---------------------------------------------------------------------------
-- The reading that was always right: no BeamNG vehicle has zero parts, so every
-- source answering empty means "ask again in a moment". This must NOT become a
-- whitelist of a car with no configuration -- that would put an entry on the
-- list matching nothing, which is the failure the empty-parts guard exists for.
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
settle()
clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() == nil, 'a car with no parts anywhere is not whitelisted')
check(refusal() and refusal():find('press again', 1, true) ~= nil,
  'and the driver is told to press again, which is the true answer here')
-- ...and the car is asked to push its parts up, so the next press has something
-- to read. Without this the refusal is permanent on a server: nothing else in
-- the mod ever asks, and GE-side part state does not fill itself in.
check(primed, 'the vehicle is asked to send its parts so the retry can work')

-- ---------------------------------------------------------------------------
-- 4. A BUILD WITH NO SOURCE AT ALL gets a different answer
-- ---------------------------------------------------------------------------
-- "Try again" is advice, and advice that can never come good is worse than an
-- error: a driver will press the button all evening. A build exposing neither
-- source is a different fact and says a different thing.
partmgmtPresent, vehicleManagerPresent = false, false
settle()
clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() == nil, 'nothing is sent when nothing can be read')
local why = refusal()
check(why and why:find('press again', 1, true) == nil,
  'and it does NOT invite a retry, because waiting will never help (got: '
    .. tostring(why) .. ')')
partmgmtPresent, vehicleManagerPresent = true, true

-- ---------------------------------------------------------------------------
-- 5. The diagnosis command runs without a vehicle, and without sources
-- ---------------------------------------------------------------------------
-- It is reached for exactly when things are broken, so it has to survive the
-- broken states rather than raise inside them and hide the answer.
partmgmtConfig, vehicleDataConfig = realConfig('Stock'), nil
check(pcall(RM.diagnoseVehicleConfig), 'the diagnosis runs on a healthy car')
partmgmtPresent, vehicleManagerPresent = false, false
check(pcall(RM.diagnoseVehicleConfig), 'and on a build with no source at all')
partmgmtPresent, vehicleManagerPresent = true, true
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, nil
check(pcall(RM.diagnoseVehicleConfig), 'and on a car that will not report parts')

-- ---------------------------------------------------------------------------
-- 6. THE CAR ANSWERS FOR ITSELF
-- ---------------------------------------------------------------------------
-- The real fix for the reported bug. Both GE-side sources report a config with
-- ZERO parts on a BeamMP client -- measured, not assumed: the panel prints
-- '[partmgmt=0, vehData=0]'. They are caches the VEHICLE fills by pushing its
-- state up, and nothing spawns a BeamMP car through the path that pushes, so
-- they stay empty for the whole session however long you wait.
--
-- So the car is asked directly, and answers into M.onVehicleParts. That is a
-- message, not a call, which is why the first press primes and the second
-- succeeds.
-- A spawn refunds the probe budget, which is what a real client gets: the
-- budget is per CAR, not per session, so a car that will not answer costs three
-- questions and then silence until a new one appears.
RM.onVehicleSpawned(VEH_ID)
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
advance(20)
clearLog()
primed = false
RM.whitelistCurrentVehicle()
check(whitelisted() == nil, 'the first press cannot answer yet')
check(primed, 'but it asks the car')

-- The cooldown holds, so hammering the button does not hammer the vehicle.
primed = false
RM.whitelistCurrentVehicle()
check(not primed, 'a second press moments later does not re-ask the car')
-- ...and it is a cooldown, not a latch: it lifts with time. A PRESS waits about
-- two seconds rather than the poll's fifteen -- a person asking is not the timer
-- coming round, and making them wait fifteen seconds for an answer the car could
-- give at once is the button feeling broken all over again.
advance(3)
primed = false
RM.whitelistCurrentVehicle()
check(primed, 'but it asks again once the cooldown has run, so a car that was '
  .. 'genuinely still loading gets asked a second time')

-- The car replies, as it would through queueGameEngineLua.
RM.onVehicleParts(realConfig('Race Build'))
settle()
clearLog()
RM.whitelistCurrentVehicle()
p = whitelisted()
check(p ~= nil, 'and the second press whitelists it, from what the car said')
-- The parts table is DIGESTED rather than carried, by the same function the car
-- uses, so this route and the car's own produce one identical signature shape.
-- The raw part names never enter the signature: a signature is an identity to
-- compare, not a copy of the build.
check(p and p.sig:find('|pd=2:', 1, true) ~= nil,
  'a parts table read on this side becomes the same digest shape the car sends')
check(p and p.sig:find('etk800_body', 1, true) == nil,
  'and the raw part names are not carried into it')
check(p and p.partsSig ~= p.sig,
  'the two halves still separate build from tuning, which is what makes Parts '
    .. 'and Strict different rules')

-- An empty answer is not an answer: it must not overwrite a good one or count
-- as a configuration in its own right.
RM.onVehicleParts({ parts = {}, vars = {} })
settle()
clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() ~= nil, 'an empty reply does not discard the good answer')

-- ---------------------------------------------------------------------------
-- 7. NOTHING LEAKED TO THE GLOBAL TABLE
-- ---------------------------------------------------------------------------
-- Twice in this change a `local` was declared BELOW the function that used it,
-- which in Lua is not an error: the name silently becomes a global, the upvalue
-- is never written, and the feature fails in a way no syntax check sees. The
-- extension owns exactly one global, its module table.
do
  local allowed = { raceManager = true }
  local leaked = {}
  for _, k in ipairs({ 'vehParts', 'lastReportedSig', 'configCheckLeft',
                       'parts', 'vars', 'cfg', 'detail', 'notes', 'offered' }) do
    if rawget(_G, k) ~= nil and not allowed[k] then leaked[#leaked + 1] = k end
  end
  check(#leaked == 0,
    'no extension local escaped into _G (found: ' .. table.concat(leaked, ', ')
      .. '): a local declared below its user becomes a global and the upvalue '
      .. 'it was meant to be is never written')
end

-- ---------------------------------------------------------------------------
-- 8. A CAR THAT WILL NOT ANSWER IS NOT GUESSED AT
-- ---------------------------------------------------------------------------
-- There used to be a fallback here: when no parts could be read, the signature
-- was built from `partConfig` instead. It worked, and it is what made the
-- Garage List usable again after the 0.11 regression -- but it was a SECOND
-- SHAPE, and section 11 below is the car that got deleted because of it.
--
-- The spawn config is still read, and still carries real information: it is in
-- the STRICT half of the signature. What it may no longer do is stand in for a
-- missing digest, because then the same car declares two different things
-- depending on whether it has answered yet.
RM.onVehicleSpawned(VEH_ID)
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
partConfigField = 'vehicles/bx/200bx_base_A.pc'
advance(20)
settle(); clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() == nil,
  'a car whose parts cannot be read is not whitelisted from a guess: a bare '
    .. '.pc path is not a document, and the car itself reports no parts')
check(refusal() and refusal():find('press again', 1, true) ~= nil,
  'the admin is asked to press again instead')

-- Two configs whose PARTS are the same are the same car to a lock, whatever
-- file each was built from.
local sameParts = { legran_body = 'wagon', legran_engine = 'i4' }
respawnWith(treeConfig(sameParts), '0:0:0:0', '3:24:11:22')
settle(); clearLog(); RM.whitelistCurrentVehicle()
local buildA = whitelisted()
respawnWith(treeConfig(sameParts), '0:0:0:0', '3:24:11:22')
settle(); clearLog(); RM.whitelistCurrentVehicle()
local buildB = whitelisted()
-- Two saved configs whose PARTS are identical are the same car as far as a
-- lock is concerned, and the file they were spawned from is not a lock.
--
-- This used to assert the opposite, because the signature carried a hash of the
-- whole `partConfig` string. That string is the entire configuration -- parts,
-- tuning AND livery -- so it moved on every change, and Strict blocked
-- everything including the paint design both modes leave free. It was reported
-- from a live session in exactly those words.
check(buildA and buildB and buildA.sig == buildB.sig,
  'two spawn configs with the same parts and tuning give the same signature: '
    .. 'the file a car was built from is not one of the locks')
check(buildA and buildB and buildA.sig:find('pc=', 1, true) == nil,
  'and the raw configuration blob is not in the signature at all -- it contains '
    .. 'the livery, so anything built from it blocks a paint job')

-- ---------------------------------------------------------------------------
-- 9. THE PROBE MUST NOT CARRY THE CONFIGURATION BACK
-- ---------------------------------------------------------------------------
-- Reported from a live session: change a part on an approved car and the game
-- freezes every few seconds afterwards.
--
-- The cause was this file's own idea. The probe asked the car for its parts and
-- brought them back as
--
--     obj:queueGameEngineLua('raceManager.onVehicleParts(' .. serialize(cfg) .. ')')
--
-- which turns a whole vehicle configuration into Lua SOURCE and makes the
-- engine compile it. While the config was empty that cost nothing, which is why
-- it looked fine in testing. Changing a part fills the config in, and the same
-- line becomes a multi-kilobyte chunk parsed every few seconds forever.
--
-- The car answers with a COUNT now. This pins that: the question may be asked,
-- the answer may not be paid for.
do
  local sawSerialize = false
  for i = 1, #queued do
    if queued[i]:find('serialize', 1, true) then sawSerialize = true end
  end
  check(#queued > 0, 'the car was asked something at all')
  check(not sawSerialize,
    'nothing queued into the vehicle serializes its configuration back: that is '
      .. 'a whole config compiled as Lua source every few seconds, which is a '
      .. 'game that freezes on a timer')
  local longest = 0
  for i = 1, #queued do
    if #queued[i] > longest then longest = #queued[i] end
  end
  check(longest < 4096, string.format(
    'and the largest thing asked of the vehicle is %d bytes: this crosses a VM '
      .. 'boundary on a timer, so it stays a question rather than a payload',
    longest))
end

-- THE CAP BELONGS TO THE POLL, NOT TO THE PERSON.
--
-- The budget stops the background timer talking to a silent car for the rest of
-- the evening. It used to apply to the button too, and the ordering made that
-- absurd: the poll spent all three questions within seconds of the car
-- appearing, so by the time an admin actually pressed Whitelist there were none
-- left and the one ask a human wanted was the only one that never happened.
do
  RM.onVehicleSpawned(VEH_ID)
  local before = #queued
  advance(120)                      -- two minutes of nobody touching anything
  local polls = #queued - before
  check(polls <= 3, string.format(
    'the poll asks a silent car %d times in two minutes, then stops', polls))

  before = #queued
  for _ = 1, 5 do
    advance(3)
    RM.whitelistCurrentVehicle()
  end
  check(#queued - before >= 5, string.format(
    'but five presses ask five times (%d): a person asking is always allowed to',
    #queued - before))
end

-- ---------------------------------------------------------------------------
-- 10. THE DIGEST: a build identity, and a part change that shows up
-- ---------------------------------------------------------------------------
-- The car computes 'count:length:hashA:hashB' over its parts and its tuning and
-- sends back two short strings. That is what makes three things possible at
-- once: no freeze (nothing large crosses), a part change that moves the
-- signature, and Parts/Strict that are genuinely different rules.
RM.onVehicleSpawned(VEH_ID)
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
partConfigField = 'vehicles/bx/ESRA BX.pc'
advance(20)

RM.onVehicleDigest('47:1832:1234567:7654321', '12:96:11111:22222')
settle()
clearLog()
RM.whitelistCurrentVehicle()
p = whitelisted()
check(p ~= nil, 'a car that reports a digest is whitelisted from it')
check(p and p.sig:find('pd=47:1832', 1, true) ~= nil,
  'the signature is built from the digest, not the spawn config: only the '
    .. 'digest can see what the car is built from RIGHT NOW')
check(p and p.partsSig ~= p.sig,
  'and the two halves differ, so Parts and Strict are different rules')
check(p and p.partsSig:find('vd=', 1, true) == nil,
  'Parts covers the build only: the tuning is not in the parts half')
check(p and p.sig:find('vd=12:96', 1, true) ~= nil,
  'and Strict adds the tuning on top')

-- Rubbish from the vehicle VM is refused rather than believed: it arrives as a
-- string built in another Lua state and ends up in a rule the server enforces.
local good = p.sig
RM.onVehicleDigest('nonsense', 'also nonsense')
settle()
clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() and whitelisted().sig == good,
  'a malformed digest is discarded, not written into the signature')

do
  local d1 = RM.digestForTest({ body = 'a', engine = 'b' })
  local d2 = RM.digestForTest({ body = 'a', engine = 'c' })
  local d3 = RM.digestForTest({ engine = 'b', body = 'a' })
  check(d1 ~= d2, 'two different builds digest differently')
  check(d1 == d3, 'and key ORDER does not matter: the same build always digests '
    .. 'the same, whichever order the table happens to iterate in')
  check(d1:match('^%d+:%d+:%d+:%d+$') ~= nil, 'the digest keeps its shape')
  check(RM.digestForTest(nil) == '0:0:0:0', 'and nothing digests to a known nothing')
end

-- ---------------------------------------------------------------------------
-- 11. ONE SIGNATURE SHAPE, EVER
-- ---------------------------------------------------------------------------
-- Reported live, and it deleted a car: on PARTS mode -- where the tuning is
-- supposed to be free -- re-tuning an approved car removed it.
--
-- The cause was not the tuning rule. This file used to have TWO signature
-- shapes. An untouched car reports no digest (its config is empty), so it
-- declared 'model=bx|pc=...'; tuning fills the config in, the digest arrives,
-- and the same car starts declaring 'model=bx|pd=...'. A different string
-- matches no stored entry, so the server correctly removed a car that had done
-- nothing Parts mode forbids.
--
-- There is no second shape now. Until the car answers, nothing is declared --
-- which the server already reads as "no verdict yet", the safe state where a
-- driver is never an offender.
RM.onVehicleSpawned(VEH_ID)
partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
partConfigField = 'vehicles/bx/ESRA BX.pc'
advance(20)
settle(); clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() == nil,
  'with nothing readable yet, NOTHING is declared: no second shape to be '
    .. 'caught out by')
check(refusal() and refusal():find('press again', 1, true) ~= nil,
  'and the admin is told to press again rather than handed a signature that '
    .. 'will change under them')

local stockParts = { legran_body = 'wagon', legran_engine = 'i4' }
respawnWith(treeConfig(stockParts), '0:0:0:0', '3:24:11:22')
settle(); clearLog()
RM.whitelistCurrentVehicle()
local untouched = whitelisted()
check(untouched ~= nil, 'once it answers, the car can be whitelisted')

-- A PURE RE-TUNE, on the same build. This is the reported deletion: the car
-- was removed six seconds after a tune, in Parts mode, which frees tuning.
RM.onVehicleDigest('0:0:0:0', '9:64:5551212:1212555')
settle()
clearLog()
RM.whitelistCurrentVehicle()
local tunedOnly = whitelisted()
check(tunedOnly and tunedOnly.partsSig == untouched.partsSig,
  'RE-TUNING LEAVES THE PARTS HALF IDENTICAL, so Parts mode still matches the '
    .. 'whitelisted entry and the car is not deleted')
check(tunedOnly and tunedOnly.sig ~= untouched.sig,
  'while Strict does see it, which is the difference between the two modes')

-- A part change moves the parts half, so BOTH modes re-rule it.
respawnWith(treeConfig({ legran_body = 'wagon', legran_engine = 'v8' }),
  '0:0:0:0', '9:64:5551212:1212555')
settle(); clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() and whitelisted().partsSig ~= untouched.partsSig,
  'changing a PART does move the parts half, so Parts mode rules on it')

-- The spawn config never enters the parts half. Whether BeamNG rewrites
-- partConfig on a tune is not knowable from here, so it must not be able to
-- move the half that promises tuning is free.
respawnWith(treeConfig(stockParts), '0:0:0:0', '3:24:11:22')
settle(); clearLog()
RM.whitelistCurrentVehicle()
check(whitelisted() and whitelisted().partsSig == untouched.partsSig,
  'the spawn config name is not in the parts half: it cannot delete a car for '
    .. 'a change Parts mode allows')
check(whitelisted() and whitelisted().sig == untouched.sig,
  'and it is not in the strict half either: Strict is parts plus tuning, and a '
    .. 'new spawn config with the same parts and tuning is the same car')

-- ---------------------------------------------------------------------------
-- 12. THE TWO DIGEST IMPLEMENTATIONS MUST AGREE, EXACTLY
-- ---------------------------------------------------------------------------
-- There are two copies of this algorithm and there have to be: one in the
-- extension, one inside the string that runs in the VEHICLE Lua state. They are
-- written differently on purpose -- the vehicle one hashes incrementally,
-- because building "k=v;k=v" for a whole configuration allocates a large string
-- ON THE PHYSICS THREAD, which is what made the game hitch every few seconds
-- after a part was changed.
--
-- Different code, identical output, or a car digests one way when the engine
-- answers and another way when this side reads a parts table, stops matching
-- the entry it was whitelisted under, and is deleted for nothing.
do
  local src = readFile('lua/ge/extensions/raceManager.lua')
  local chunk = src:match('%[==%[(.-)%]==%]')
  check(chunk ~= nil, 'the vehicle-side chunk is still there to be checked')
  check(chunk and chunk:find('local function rmDigest', 1, true) ~= nil,
    'and it still carries its own copy of the digest')

  local vehDigest
  if chunk then
    local body = chunk:match('(local function rmDigest.-\n        end)')
    local mk = load or loadstring
    local fn = body and mk(body .. '\nreturn rmDigest')
    if fn then vehDigest = fn() end
  end
  check(vehDigest ~= nil, 'the vehicle digest could be lifted out and run')

  if vehDigest then
    local cases = {
      { body = 'etk800_body' },
      { body = 'etk800_body', engine = 'i6', turbo = 'none' },
      { ['$tirepressure_R'] = 30, camber = -1.5, toe = 0.0001 },
      { a = 1, b = 'x', c = -0.000012345, d = 1e12 },
      {},
    }
    local agreed = true
    for i = 1, #cases do
      if vehDigest(cases[i]) ~= RM.digestForTest(cases[i]) then agreed = false end
    end
    -- And a configuration the size of a real car, which is the case that
    -- mattered: the big one is what stalled the physics thread.
    local big = {}
    for i = 1, 300 do big['slot_' .. i] = 'part_name_' .. i end
    if vehDigest(big) ~= RM.digestForTest(big) then agreed = false end
    check(agreed,
      'the vehicle-side digest and the extension one agree on every case, '
        .. 'including a 300-part configuration: two implementations, one identity')
    check(vehDigest(nil) == RM.digestForTest(nil),
      'and they agree about nothing at all')
  end
end

-- ---------------------------------------------------------------------------
-- 13. THE SIGNATURE IS A FIXED SIZE, WHATEVER THE ENGINE HANDS OVER
-- ---------------------------------------------------------------------------
-- Reported live: the second press of Whitelist on an edited car was refused
-- with "that configuration is too long to store".
--
-- `partConfig` is a short path for a car spawned from a saved config, and for
-- one edited in the session it is the WHOLE CONFIGURATION inline -- thousands
-- of bytes. It was going into the strict signature verbatim, straight past the
-- 4000-byte cap the server enforces, so the capture was refused for a car that
-- is otherwise perfectly legal.
--
-- A signature is an identity to compare, never a copy of the thing.
RM.onVehicleSpawned(VEH_ID)
advance(20)
RM.onVehicleDigest('47:1832:1234567:7654321', '12:96:11111:22222')

respawnWith('vehicles/bx/ESRA BX.pc', '47:1832:1234567:7654321', '12:96:11111:22222')
settle(); clearLog(); RM.whitelistCurrentVehicle()
check(whitelisted() ~= nil, 'a car with a short spawn config is whitelisted')

-- The measured case: an edited car reports its whole configuration inline. The
-- live log that found the freeze showed 73,258 bytes.
respawnWith(string.rep('part=something_long_indeed;', 400),
  '47:1832:1234567:7654321', '12:96:11111:22222')
check(#partConfigField > 4000, 'the fixture really is over the server limit')
settle(); clearLog(); RM.whitelistCurrentVehicle()
local longPc = whitelisted()
check(longPc ~= nil, 'and so is one whose spawn config is the whole build inline')
check(longPc and #longPc.sig < 200, string.format(
  'the signature stays small (%d bytes) however big the configuration is: the '
    .. 'server refuses anything over 4000, and that refusal was reported live',
  longPc and #longPc.sig or -1))
check(longPc and #longPc.partsSig < 200, 'and so does the parts half')

-- READ ONCE, NOT PER POLL. This is the freeze, stated as a property: the poll
-- runs every two seconds and must not touch that 73 KB string again.
do
  local reads = 0
  local realGetField = veh.getField
  veh.getField = function (self, name)
    if name == 'partConfig' then reads = reads + 1 end
    return realGetField(self, name)
  end
  advance(60)                      -- a minute of polling
  for _ = 1, 5 do RM.whitelistCurrentVehicle() end
  veh.getField = realGetField
  check(reads == 0, string.format(
    'the spawn config is not re-read once per poll (%d reads in a minute): it '
      .. 'is tens of kilobytes on an edited car, and hashing it on a timer is '
      .. 'what froze the game every few seconds', reads))
end

-- The blob never reaches the signature now, so its size cannot matter at all.
-- What kept it small was hashing it; what keeps it out is that it describes
-- more than any lock is allowed to.
check(longPc and longPc.sig:find('pc=', 1, true) == nil,
  'the configuration blob is not in the signature, whatever size it is')

-- ---------------------------------------------------------------------------
-- 14. WHAT A DRIVER MAY CHANGE, AND UNDER WHICH LOCK
-- ---------------------------------------------------------------------------
-- The rules as the league actually wants them, which the Vehicle Config screen
-- states more precisely than "parts" and "tuning" ever did:
--
--   Parts tab, under Body   a real part. Locked under BOTH modes.
--   Parts tab, Paint Design and License Plate Design
--                           livery. FREE under both modes, always.
--   Tuning tab              free under Parts, locked under Strict.
--   Paint tab               free, always.
--
-- The trap is that livery lives in the PARTS table beside the real parts, so
-- digesting that table wholesale made choosing a police livery read exactly
-- like fitting a different engine -- and on Strict it would have deleted the
-- car for it.
do
  local body = {
    body = 'wagon_body',
    engine = 'i6_petrol',
    paint_design = 'police_livery',
    licenseplate_design_2 = 'empty',
  }

  -- Livery moves, the build does not.
  local livery = {
    body = 'wagon_body',
    engine = 'i6_petrol',
    paint_design = 'taxi_livery',          -- changed
    licenseplate_design_2 = 'novelty',     -- changed
  }
  check(RM.digestForTest(body, true) == RM.digestForTest(livery, true),
    'PAINT DESIGN AND LICENSE PLATE DESIGN ARE NOT THE BUILD: changing either '
      .. 'leaves the parts digest identical, so a livery never costs a driver '
      .. 'their car under either lock')

  -- A real part moves it.
  local swapped = {
    body = 'wagon_body',
    engine = 'v8_petrol',                  -- a real part, changed
    paint_design = 'police_livery',
    licenseplate_design_2 = 'empty',
  }
  check(RM.digestForTest(body, true) ~= RM.digestForTest(swapped, true),
    'but an ENGINE does move it, which is the change both locks exist to catch')

  -- And the filter is not a blunt match on the word "plate": a skidplate is a
  -- real part and losing it from the digest would let one be swapped freely.
  local plated = {
    body = 'wagon_body', engine = 'i6_petrol', skidplate = 'heavy',
    paint_design = 'police_livery', licenseplate_design_2 = 'empty',
  }
  local plated2 = {
    body = 'wagon_body', engine = 'i6_petrol', skidplate = 'none',
    paint_design = 'police_livery', licenseplate_design_2 = 'empty',
  }
  check(RM.digestForTest(plated, true) ~= RM.digestForTest(plated2, true),
    'a SKIDPLATE is still a part: the livery rule spells out "licenseplate" '
      .. 'rather than matching "plate" and quietly freeing real components')

  -- The tuning half is never filtered: it has no livery in it, and running a
  -- parts rule over it would be a silent way to lose a tuning change.
  local tuneA = { camber = -1.5, brakeforce = 1.0 }
  local tuneB = { camber = -2.5, brakeforce = 1.0 }
  check(RM.digestForTest(tuneA) ~= RM.digestForTest(tuneB),
    'a tuning change moves the tuning digest, which is what Strict locks and '
      .. 'Parts leaves free')
end

-- The same rule has to hold end to end, not just in the digest helper: a livery
-- change must leave the PARTS SIGNATURE alone while an engine swap moves it.
RM.onVehicleSpawned(VEH_ID)
advance(20)
RM.onVehicleDigest('12:200:4242:2424', '5:40:99:88')
settle(); clearLog(); RM.whitelistCurrentVehicle()
local liveryBase = whitelisted()
check(liveryBase ~= nil, 'the approved car is captured')

-- The car reports the same PARTS digest after a livery change, because the
-- vehicle side applies the identical filter.
RM.onVehicleDigest('12:200:4242:2424', '5:40:99:88')
settle(); clearLog(); RM.whitelistCurrentVehicle()
check(whitelisted() and whitelisted().partsSig == liveryBase.partsSig
    and whitelisted().sig == liveryBase.sig,
  'a livery change moves neither half, so it is legal under Parts AND Strict')

-- Tuning: Parts half untouched, Strict half moves.
RM.onVehicleDigest('12:200:4242:2424', '6:52:1234:5678')
settle(); clearLog(); RM.whitelistCurrentVehicle()
local retuned = whitelisted()
check(retuned and retuned.partsSig == liveryBase.partsSig,
  'a re-tune leaves the parts half alone: legal under Parts')
check(retuned and retuned.sig ~= liveryBase.sig,
  'and moves the strict half: caught under Strict')

-- A body part: both halves move, so both locks catch it.
RM.onVehicleDigest('13:214:777:888', '6:52:1234:5678')
settle(); clearLog(); RM.whitelistCurrentVehicle()
check(whitelisted() and whitelisted().partsSig ~= liveryBase.partsSig,
  'a part under Body moves the parts half: caught under both locks')

-- ---------------------------------------------------------------------------
-- 15. BOTH COPIES OF THE COSMETIC RULE MUST AGREE TOO
-- ---------------------------------------------------------------------------
-- Same hazard as the digest itself: the rule lives twice, once here and once in
-- the vehicle chunk. Livery skipped on one side and counted on the other means
-- a car digests differently depending on which side answered, stops matching
-- its own entry, and is deleted for a paint job.
do
  local src = readFile('lua/ge/extensions/raceManager.lua')
  local chunk = src:match('%[==%[(.-)%]==%]')
  local vehBody = chunk and chunk:match('(local function rmCosmetic.-\n        end)')
  local geBody  = src:match('(local function isCosmeticSlot.-\nend)')
  local mk = load or loadstring
  local vehFn = vehBody and mk(vehBody .. '\nreturn rmCosmetic')
  local geFn  = geBody  and mk(geBody  .. '\nreturn isCosmeticSlot')
  check(vehFn ~= nil and geFn ~= nil, 'both cosmetic rules could be lifted out')
  if vehFn and geFn then
    vehFn, geFn = vehFn(), geFn()
    local names = {
      'paint_design', 'licenseplate_design_2', 'license_plate_front',
      'body', 'engine', 'skidplate', 'skin_main', 'livery_1', 'decal_side',
      'Paint_Design', 'LICENSEPLATE_DESIGN', 'suspension_F', 'transmission',
      'exhaust', 'paintdesign', 'plate_holder',
    }
    local agreed = true
    for i = 1, #names do
      if vehFn(names[i]) ~= geFn(names[i]) then agreed = false end
    end
    check(agreed, 'the two cosmetic rules agree on every slot name')
    check(geFn('paint_design') and geFn('licenseplate_design_2'),
      'Paint Design and License Plate Design are livery, never the build')
    check(not geFn('body') and not geFn('engine'),
      'Body and engine are the build')
    check(not geFn('skidplate') and not geFn('plate_holder'),
      'and a skidplate is a part: the rule does not free real components by '
        .. 'matching the word "plate" loosely')
  end
end

-- ---------------------------------------------------------------------------
-- 16. THE PARTS COME OUT OF THE SPAWN CONFIG WHEN THE CAR HAS NONE
-- ---------------------------------------------------------------------------
-- The live client reports, verbatim:
--
--     pd=0:0:0:0   vd=15:241:2524357651:342463952   pc=73363:...
--
-- The car knows its fifteen tuning values and NO PARTS AT ALL -- not from
-- partmgmt, not from the per-vehicle store, not from its own Lua VM. So the
-- parts half of the signature was a constant, and a body part could be swapped
-- freely under Parts mode: it was reported as allowed on a live server.
--
-- The parts were never missing. They are inside `partConfig`, which for an
-- edited car is the whole configuration written out. It is parsed once per car
-- -- never on a poll, that is the freeze -- and its parts are digested on the
-- same livery rule as any other parts table.
do
  local function inlineConfig(parts)
    -- What the engine hands over for an edited car: the configuration itself
    -- rather than a path to one.
    local bits = {}
    for k, v in pairs(parts) do bits[#bits + 1] = '"' .. k .. '":"' .. v .. '"' end
    table.sort(bits)
    return '{"parts":{' .. table.concat(bits, ',') .. '},"vars":{"camber":-1.5}}'
  end

  -- jsonDecode is a stub in this harness; give it something real to do.
  local realDecode = jsonDecode
  jsonDecode = function (str)
    if type(str) ~= 'string' or str:sub(1, 1) ~= '{' then return realDecode(str) end
    local parts = {}
    local inner = str:match('"parts":{(.-)}')
    if inner then
      for k, v in inner:gmatch('"([^"]+)":"([^"]*)"') do parts[k] = v end
    end
    return { parts = parts, vars = { camber = -1.5 } }
  end

  local stockParts = { body = 'wagon', engine = 'i6', paint_design = 'police' }
  local swapped    = { body = 'wagon', engine = 'v8', paint_design = 'police' }
  local reliveried = { body = 'wagon', engine = 'i6', paint_design = 'taxi' }

  -- The car answers with NOTHING, exactly as the live one does.
  respawnWith(inlineConfig(stockParts), '0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local approved = whitelisted()
  check(approved ~= nil, 'the car is captured')
  check(approved and approved.partsSig ~= 'model=etk800|pd=0:0:0:0',
    'AND ITS PARTS HALF IS REAL, dug out of the spawn configuration, where a '
      .. 'car that reports no parts left it as a constant that matched anything')

  -- An engine swap: the parts half must move, so PARTS mode rules on it.
  respawnWith(inlineConfig(swapped), '0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig ~= approved.partsSig,
    'swapping the ENGINE moves the parts half, so Parts mode removes the car '
      .. '-- it was allowed on a live server before this')

  -- A livery change must NOT, on the same rule as everywhere else.
  respawnWith(inlineConfig(reliveried), '0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig == approved.partsSig,
    'changing the livery does not, even though it lives in the same parts '
      .. 'table: the filter applies wherever the parts came from')

  -- Tuning still comes from the CAR, because a re-tune does not rebuild it and
  -- so never reaches the spawn configuration.
  RM.onVehicleDigest('0:0:0:0', '16:260:1111:2222')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local retuned = whitelisted()
  check(retuned and retuned.partsSig == whitelisted().partsSig,
    'a re-tune leaves the parts half alone')
  check(retuned and retuned.sig:find('vd=16:260', 1, true) ~= nil,
    'and the tuning half still comes from the car, which is the only source '
      .. 'that sees a tune with no rebuild behind it')

  -- A PATH rather than a configuration parses to nothing and changes nothing.
  respawnWith('vehicles/legran/police.pc', '0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() == nil,
    'A CAR WHOSE PARTS NOBODY CAN READ IS NOT DECLARED AT ALL. A bare .pc path '
      .. 'is not a document and the car itself reports no parts, so the only '
      .. 'honest parts digest is "unknown" -- and the alternative, declaring '
      .. 'the digest of nothing, is a value every car matches and the one that '
      .. 'deleted an approved car six seconds after a re-tune. Silence means '
      .. 'no verdict, which is the state where a driver is never an offender.')

  jsonDecode = realDecode
end

-- ---------------------------------------------------------------------------
-- 17. THE REAL partConfig FORMAT, AS THE GAME ACTUALLY WRITES IT
-- ---------------------------------------------------------------------------
-- Section 16 uses a fixture shaped the way this file GUESSED the config looked.
-- This one uses the shape a live client printed into the console:
--
--   {["partsTree"]={["chosenPartName"]="legran",["suitablePartNames"]=...,
--     ["partPath"]="/legran/",["children"]={["paint_design"]={...}}}}
--
-- Two bugs hid behind that guess, and neither could fail in a harness:
--
--   * It is LUA, not JSON. jsonDecode was being handed it on every read and
--     printing a stack trace each time -- a wall of red for a value that was
--     never going to parse.
--
--   * It has to be loaded with `loadstring`. BeamNG runs LuaJIT, where `load`
--     takes a FUNCTION and rejects a string. Written `load or loadstring` it
--     worked here (5.3 accepts a string) and could not work in the game. A test
--     that only ran on this Lua would call that fixed forever.
--
-- And the parts are a TREE, not a flat table, so `cfg.parts` found nothing even
-- once it parsed. The parser is lifted out and run on the real shape.
do
  local src = readFile('lua/ge/extensions/raceManager.lua')
  local treeFn = src:match('(local function collectPartsTree.-\nend)')
  local parseFn = src:match('(local function partsFromConfigString.-\n  return cfg%.parts\nend)')
  check(treeFn ~= nil and parseFn ~= nil, 'the config parser is there to check')

  local parse
  if treeFn and parseFn then
    local mk = loadstring or load
    local fn = mk(treeFn .. '\n' .. parseFn .. '\nreturn partsFromConfigString')
    if fn then parse = fn() end
  end
  check(parse ~= nil, 'and it could be lifted out and run')

  if parse then
    local function cfg(engine, livery, plate)
      return '{["partsTree"]={["chosenPartName"]="legran",["children"]={'
        .. '["paint_design"]={["chosenPartName"]="' .. livery .. '",["children"]={}},'
        .. '["licenseplate_design_2"]={["chosenPartName"]="' .. plate .. '",["children"]={}},'
        .. '["legran_engine"]={["chosenPartName"]="' .. engine .. '",["children"]={'
        ..   '["legran_turbo"]={["chosenPartName"]="turbo_sport",["children"]={}}}},'
        .. '["legran_body"]={["chosenPartName"]="legran_body_wagon",["children"]={}}'
        .. '}}}'
    end

    local base = parse(cfg('engine_i4', 'skin_police', 'plate_a'))
    check(base ~= nil, 'the REAL format parses, which it did not before')
    -- KEYED BY SLOT NAME, not by path. BeamMP's spawn record is a flat
    -- slot -> part map, so the tree has to flatten the same way or one car
    -- digests two ways depending on which source answered. BeamJoy flattens
    -- the identical engine data the identical way.
    check(base and base['legran_engine'] == 'engine_i4',
      'a top-level slot comes out with its chosen part')
    check(base and base['legran_turbo'] == 'turbo_sport',
      'and a NESTED one does too: a turbo hangs off the engine, and a walk that '
        .. 'stopped at the first level would let it be swapped freely')

    -- The whole point, end to end.
    local function pdOf(c) return RM.digestForTest(parse(c), true) end
    check(pdOf(cfg('engine_i4', 'skin_police', 'plate_a'))
        == pdOf(cfg('engine_i4', 'skin_taxi', 'plate_b')),
      'CHANGING THE LIVERY AND THE PLATE LEAVES THE PARTS DIGEST IDENTICAL, so '
        .. 'neither lock touches a paint job')
    check(pdOf(cfg('engine_i4', 'skin_police', 'plate_a'))
        ~= pdOf(cfg('engine_v8', 'skin_police', 'plate_a')),
      'and swapping the ENGINE moves it, so both locks rule on it -- this is '
        .. 'the case that was reported as allowed on a live server')

    check(parse('vehicles/legran/police.pc') == nil,
      'a saved-config PATH is not a document and parses to nothing, without '
        .. 'that being an error')
  end
end

-- ---------------------------------------------------------------------------
-- 18. A CONFIG THAT IS NOT READY YET IS NOT A CONFIG THAT IS EMPTY
-- ---------------------------------------------------------------------------
-- The spawn config is read once per car, because it is tens of kilobytes and
-- re-reading it on a poll is what froze the game. But "once" must not include
-- once BEFORE the engine has filled it in: the poll runs a second after the
-- spawn, and a car that young can still have nothing there.
--
-- Caching that made the failure permanent for the vehicle. The parts digest
-- fell back to the car's own answer -- zero parts -- and stayed there, so the
-- signature stopped matching the entry the car had been whitelisted under and
-- every mode refused it. Reported as "blocking everything".
do
  RM.onVehicleSpawned(VEH_ID)
  partConfigField = nil                    -- not filled in yet
  advance(20)
  settle(); clearLog(); RM.whitelistCurrentVehicle()

  check(whitelisted() == nil, 'nothing is declared while there is nothing to read')

  -- Now the engine provides it, with no second spawn: this is the same car.
  partConfigField = '{["partsTree"]={["chosenPartName"]="legran",["children"]={'
    .. '["legran_body"]={["chosenPartName"]="wagon",["children"]={}}}}}'
  advance(20)
  -- The car answers with its TUNING. Both halves have to be known before
  -- anything is declared: the parts arrive from the configuration at once and
  -- the tuning does not, and declaring on the parts alone produced a second
  -- signature a second later for a car nobody had touched.
  RM.onVehicleDigest('0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local after = whitelisted()
  check(after ~= nil,
    'a config that arrives AFTER the first read is still picked up: the empty '
      .. 'read is not cached, because it means "ask again" and not "this car '
      .. 'has none"')
  check(after and after.partsSig ~= 'model=etk800|pd=0:0:0:0',
    'and its parts are real, rather than the zero the car itself reports -- '
      .. 'which is the value that stopped matching the whitelisted entry')
end

-- ---------------------------------------------------------------------------
-- 19. ONE SOURCE THAT ANSWERS THE SAME WAY IN BOTH STATES
-- ---------------------------------------------------------------------------
-- The bug this closes, and it is the one that made every mode block everything.
--
-- `partConfig` is TWO different things depending on what the driver has done:
--
--   spawned from a saved config   "vehicles/legran/derby_wagon.pc"   30 bytes
--   edited in the session         {["partsTree"]={...}}              73 KB
--
-- So a parts digest taken from it is 0:0:0:0 for the stock car and a real value
-- the instant anything is touched -- INCLUDING the paint. Whitelist the stock
-- car, change its livery, and the parts half moves for a reason the livery
-- filter never sees, because the change is in which SOURCE answered rather than
-- in any slot.
--
-- BeamMP's spawn record carries a flat `parts` table in both states. The
-- console printed it in full:
--
--   vcf = { partConfigFilename = "vehicles/legran/derby_wagon.pc",
--           parts = {...}, vars = {...}, paints = {...} }
--
-- so that is what the parts half is built from, and `partConfig` is only the
-- fallback for a client where it cannot be reached.
do
  local mpParts = nil
  local realMP = MPVehicleGE
  MPVehicleGE = {
    isOwn = function (id) return id == VEH_ID end,
    getVehicles = function ()
      return { { gameVehicleID = VEH_ID, vcf = { parts = mpParts } } }
    end,
  }

  local stock = {
    legran_body = 'wagon', legran_engine = 'i4',
    paint_design = 'police', licenseplate_design_2 = 'plate_a',
  }

  -- The car is spawned from a SAVED CONFIG: partConfig is a path with nothing
  -- in it, and BeamMP is the only source with the parts.
  mpParts = stock
  respawnWith('vehicles/legran/derby_wagon.pc')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local approved = whitelisted()
  check(approved ~= nil, 'the stock car is captured from the BeamMP record')
  check(approved and approved.partsSig ~= 'model=etk800|pd=0:0:0:0',
    'with REAL parts, where a 30-byte path gave nothing to compare and the '
      .. 'lock matched every car')

  -- The driver changes the livery. In the game this turns partConfig into a
  -- 73 KB document -- a completely different source -- and the parts half must
  -- not notice.
  mpParts = {
    legran_body = 'wagon', legran_engine = 'i4',
    paint_design = 'taxi', licenseplate_design_2 = 'plate_b',
  }
  respawnWith('{["partsTree"]={["chosenPartName"]="legran",["children"]={'
    .. '["legran_body"]={["chosenPartName"]="wagon",["children"]={}}}}}')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig == approved.partsSig,
    'A LIVERY CHANGE LEAVES THE PARTS HALF IDENTICAL even though partConfig has '
      .. 'gone from a path to a document: the identity follows the parts, not '
      .. 'whichever source happened to be readable')

  -- An engine swap must still move it.
  mpParts = {
    legran_body = 'wagon', legran_engine = 'v8',
    paint_design = 'taxi', licenseplate_design_2 = 'plate_b',
  }
  respawnWith('{["partsTree"]={["chosenPartName"]="legran",["children"]={}}}')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig ~= approved.partsSig,
    'and an ENGINE SWAP still moves it, so both locks rule on a real change')

  MPVehicleGE = realMP
end

-- ---------------------------------------------------------------------------
-- 20. ONE UNTOUCHED CAR, ONE SIGNATURE
-- ---------------------------------------------------------------------------
-- The last form this bug took, and the log named it exactly:
--
--   Declared [digest, changed: PARTS+TUNING]: model=legran|pd=121:6778:...|vd=0:0:0:0
--
-- PARTS+TUNING moved on a car nobody had touched. The parts had started
-- arriving synchronously, out of the spawn configuration, while the tuning
-- still comes from the car and takes a moment -- so the guard that waited for
-- the parts let a declaration out with a placeholder tuning, and a second one
-- followed with the real value. Whitelist either and the other is refused.
--
-- Nothing is declared until BOTH halves are known.
do
  RM.onVehicleSpawned(VEH_ID)
  partConfigField = '{["partsTree"]={["chosenPartName"]="legran",["children"]={'
    .. '["legran_body"]={["chosenPartName"]="wagon",["children"]={}},'
    .. '["paint_design"]={["chosenPartName"]="police",["children"]={}}}}}'
  advance(20)

  -- The parts are readable at once; the car has not reported its tuning.
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() == nil,
    'the parts alone are not a signature: a declaration now would carry a '
      .. 'placeholder tuning and be replaced a second later')

  -- Now it answers, and THAT is the first and only signature for this car.
  RM.onVehicleDigest('0:0:0:0', '15:241:2524357651:342463952')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local first = whitelisted()
  check(first ~= nil, 'once the tuning is in, the car is captured')
  check(first and first.sig:find('vd=15:241', 1, true) ~= nil,
    'with the real tuning rather than a placeholder')

  -- Nothing about the car has changed, so nothing about its signature may.
  advance(60)
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().sig == first.sig,
    'AND IT DOES NOT MOVE AGAIN on an untouched car: one car, one signature, '
      .. 'however long it sits there')
end

-- ---------------------------------------------------------------------------
-- 21. A SIGNATURE MUST NOT MOVE ON ITS OWN
-- ---------------------------------------------------------------------------
-- Measured across three spawns of one untouched car, straight from the console:
--
--   vd=15:241:2524357651:342463952
--   vd=15:247:2584485279:2857557430
--   vd=15:247:416246747:2147427886
--
-- Fifteen tuning values every time and three different digests. The tuning was
-- not changing; its FLOATS were, in the last places, and '%.6g' wrote every one
-- of those digits down faithfully. So the signature drifted between spawns and
-- could never match the entry the car had been whitelisted under -- which is a
-- car deleted for nothing, over and over.
--
-- Quantized to fixed three decimals: finer than any tuning control a driver can
-- set, coarse enough that re-derived floats land on the same string.
do
  local a, b = {}, {}
  for i = 1, 15 do
    local v = i * 0.7
    a['$var_' .. i] = v
    b['$var_' .. i] = v + (i % 3 == 0 and 1e-9 or 0)
  end
  check(RM.digestForTest(a) == RM.digestForTest(b),
    'float noise in the last places does NOT move the tuning digest: a car '
      .. 'nobody has touched keeps its identity across a respawn')

  local c = {}
  for k, v in pairs(a) do c[k] = v end
  c['$var_3'] = c['$var_3'] + 0.01
  check(RM.digestForTest(a) ~= RM.digestForTest(c),
    'but a real 0.01 change still moves it, so Strict has not been blunted')

  -- The vehicle-side copy has to quantize identically, or the two sources
  -- disagree about a car that has not changed.
  local src = readFile('lua/ge/extensions/raceManager.lua')
  local chunk = src:match('%[==%[(.-)%]==%]')
  check(chunk and chunk:find('%.3f', 1, true) ~= nil,
    'the vehicle-side digest quantizes to the same three decimals')
  check(src:find("string.format('%.6g'", 1, true) == nil,
    'and nothing anywhere still writes raw float digits into an identity')
end

-- ---------------------------------------------------------------------------
-- 22. THE STOCK CAR, WHICH IS THE ONE A LEAGUE ACTUALLY APPROVES
-- ---------------------------------------------------------------------------
-- A car spawned from a saved config exposes nothing to ask afterwards. The
-- panel said it in four numbers:
--
--     [partmgmt=0, vehData=0, car=0, pc=40]
--
-- Forty bytes is "vehicles/racetruck/Pro 4 (Sequential).pc" -- a path, not a
-- document -- and every other source reports zero. So the stock car could not
-- be whitelisted at all, while an EDITED one could, which is backwards: the
-- stock car is the one a league wants to approve.
--
-- The parts are not hidden. BeamMP is handed them in the spawn event and keeps
-- only a summary, so the event is wrapped and they are taken as they pass.
do
  local realMP = MPVehicleGE
  local spawnHandler = function () end
  MPVehicleGE = {
    isOwn = function (id) return id == VEH_ID end,
    getVehicles = function () return {} end,
    onServerVehicleSpawned = function (...) return spawnHandler(...) end,
  }

  -- The poll installs the watch.
  advance(4)

  -- BeamMP receives a spawn: a saved-config car, with its parts in the payload.
  local delivered = false
  spawnHandler = function () delivered = true end
  MPVehicleGE.onServerVehicleSpawned(0, {
    vid = VEH_ID,
    vcf = {
      model = 'racetruck',
      partConfigFilename = 'vehicles/racetruck/Pro 4 (Sequential).pc',
      parts = { racetruck_body = 'pro4', racetruck_engine = 'v8',
                paint_design = 'blastr' },
      vars = { camber = -1.5 },
    },
  })
  check(delivered,
    'the original handler still runs: catching the parts must never cost a '
      .. 'player their car spawning')

  -- Now the car appears, with nothing readable on it but that path.
  RM.onVehicleSpawned(VEH_ID)
  partConfigField = 'vehicles/racetruck/Pro 4 (Sequential).pc'
  partmgmtConfig, vehicleDataConfig = { parts = {}, vars = {} }, { parts = {}, vars = {} }
  advance(20)
  RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local approved = whitelisted()
  check(approved ~= nil,
    'A STOCK CAR CAN BE WHITELISTED: its parts came from the spawn event, '
      .. 'which is the only place they were ever visible')
  check(approved and approved.partsSig ~= 'model=etk800|pd=0:0:0:0',
    'and the parts half is real rather than the digest of nothing')

  -- The livery is filtered on the same rule, wherever the parts came from.
  local withLivery = approved.partsSig
  MPVehicleGE.onServerVehicleSpawned(0, {
    vid = VEH_ID,
    vcf = { parts = { racetruck_body = 'pro4', racetruck_engine = 'v8',
                      paint_design = 'different_livery' } },
  })
  RM.onVehicleSpawned(VEH_ID)
  advance(20)
  RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig == withLivery,
    'a livery change does not move it, on the same filter as every other route')

  -- ...and a real part still does.
  MPVehicleGE.onServerVehicleSpawned(0, {
    vid = VEH_ID,
    vcf = { parts = { racetruck_body = 'pro4', racetruck_engine = 'v6',
                      paint_design = 'different_livery' } },
  })
  RM.onVehicleSpawned(VEH_ID)
  advance(20)
  RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() and whitelisted().partsSig ~= withLivery,
    'and swapping the engine does')

  MPVehicleGE = realMP
end

-- ---------------------------------------------------------------------------
-- 23. THE PARTS ARE IN partsTree, NOT IN parts
-- ---------------------------------------------------------------------------
-- The bug that made this feature fail every time it was tested, for its whole
-- life. The live panel read
--
--     [partmgmt=0, vehData=0, car=0, pc=31]
--
-- and every fix went looking for a missing source. Nothing was missing:
-- core_vehicle_manager.getVehicleData(id).config carries `partsTree`, `parts`
-- on that same table is empty, and this file only ever read `parts`.
--
-- Confirmed against BeamJoy, which reads partsTree off the same call and works
-- in production. Its flattening is copied exactly, slot name to chosen part,
-- because BeamMP's spawn record is a flat slot map and the two must agree.
--
-- The car's own answer is pinned here too: it reports its tuning and NO parts,
-- and that empty answer used to outrank a full parts list and refuse the read.
do
  local function tree(parts)
    local kids = {}
    for slot, part in pairs(parts) do
      kids[slot] = { chosenPartName = part, children = {} }
    end
    return { chosenPartName = 'BWR_Pro2', children = kids }
  end
  local function liveCar(parts, vars)
    -- Exactly the live client: the part manager empty, no BeamMP config, a .pc
    -- path with nothing in it, and the tree the only thing that knows anything.
    partmgmtConfig = { parts = {}, vars = {} }
    vehicleDataConfig = { model = 'BWR_Pro_2', partsTree = tree(parts),
                          vars = vars or { camber = -1.5 } }
    clearLog()
    RM.onVehicleSpawned(VEH_ID)
    partConfigField = 'vehicles/BWR_Pro_2/75  Skoda.pc'
    advance(20)
    RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')  -- the car has NO parts
    settle(); clearLog(); RM.whitelistCurrentVehicle()
    return whitelisted()
  end

  local stock = { BWR_Pro2_body = 'pro2', BWR_Pro2_engine = 'v8',
                  paint_design = 'anderson', licenseplate_design_2 = 'plate_a' }
  local a = liveCar(stock)
  check(a ~= nil,
    'A STOCK CAR ON A LIVE CLIENT WHITELISTS: partsTree is read, where reading '
      .. 'only `parts` refused every press this feature ever received')

  local painted = {}
  for k, v in pairs(stock) do painted[k] = v end
  painted.paint_design = 'taxi'
  painted.licenseplate_design_2 = 'plate_b'
  local b = liveCar(painted)
  check(a and b and a.partsSig == b.partsSig,
    'Paint Design and License Plate Design are free: the parts half does not move')

  local swapped = {}
  for k, v in pairs(painted) do swapped[k] = v end
  swapped.BWR_Pro2_engine = 'v6'
  local c = liveCar(swapped)
  check(b and c and b.partsSig ~= c.partsSig,
    'and an engine swap does move it, so Parts actually locks the parts')

  local d = liveCar(swapped, { camber = -2.5 })
  check(c and d and c.partsSig == d.partsSig,
    'a re-tune leaves the parts half alone, which is what Parts mode allows')
  check(c and d and c.sig ~= d.sig,
    'and moves the full signature, which is what Strict blocks')
end

-- ---------------------------------------------------------------------------
-- 23b. THE CAPTURE CARRIES THE SAVED CONFIG'S PATH
-- ---------------------------------------------------------------------------
-- Without it the entry reaches the server with no `pc`, the Take button is
-- hidden because there is nothing to spawn, and the whole driver-facing half is
-- invisible with no error anywhere. Read off the SAME table the parts come
-- from, which is where BeamJoy reads it too.
do
  local function tree(parts)
    local kids = {}
    for slot, part in pairs(parts) do
      kids[slot] = { chosenPartName = part, children = {} }
    end
    return { chosenPartName = 'buggy', children = kids }
  end
  partmgmtConfig = { parts = {}, vars = {} }
  vehicleDataConfig = {
    model = 'TrackfabLightBuggy',
    partConfigFilename = 'vehicles/TrackfabLightBuggy/shortcoursesolohighoutput.pc',
    partsTree = tree({ buggy_body = 'light', buggy_engine = 'v8' }),
    vars = { camber = -1.5 },
  }
  clearLog()
  RM.onVehicleSpawned(VEH_ID)
  partConfigField = 'vehicles/TrackfabLightBuggy/shortcoursesolohighoutput.pc'
  advance(20); RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  local w = whitelisted()
  check(w ~= nil and w.pc == 'vehicles/TrackfabLightBuggy/shortcoursesolohighoutput.pc',
    'the capture sends the saved config path, which is the only thing on an '
      .. 'entry a driver can act on')

  -- A car edited in the session has no file behind it. Sending a path anyway
  -- would spawn the model's default under the approved car's name.
  vehicleDataConfig = {
    model = 'TrackfabLightBuggy',
    partsTree = tree({ buggy_body = 'light', buggy_engine = 'v6' }),
    vars = { camber = -1.5 },
  }
  clearLog()
  RM.onVehicleSpawned(VEH_ID)
  partConfigField = '{["partsTree"]={["chosenPartName"]="buggy","children"={}}}'
  advance(20); RM.onVehicleDigest('0:0:0:0', '15:120:9876:5432')
  settle(); clearLog(); RM.whitelistCurrentVehicle()
  check(whitelisted() ~= nil and whitelisted().pc == nil,
    'and sends none for a car with no saved config, so the panel can leave it out')
end

-- ---------------------------------------------------------------------------
-- 24. TAKING A CAR OFF THE GARAGE LIST
-- ---------------------------------------------------------------------------
-- The driver's half. An entry carries the saved config's PATH, and BeamNG takes
-- that verbatim: prepareConfigData in core/vehicles.lua reads opts.config as
-- "a basename or a full path" and loads the .pc itself. So nothing is rebuilt
-- here and no parts table is shipped.
--
-- replaceVehicle for Take (swaps the car under the driver, no vehicle cap) and
-- spawnNewVehicle for an extra one. Which of the two gets called is the whole
-- of what this pins, plus that the path is passed through untouched.
do
  local calls = {}
  local realCV = core_vehicles
  core_vehicles = {
    removeCurrent = function () end,
    replaceVehicle = function (model, opt)
      calls[#calls + 1] = { how = 'replace', model = model, config = opt and opt.config }
    end,
    spawnNewVehicle = function (model, opt)
      calls[#calls + 1] = { how = 'spawn', model = model, config = opt and opt.config }
    end,
  }

  local PC = 'vehicles/BWR_Pro_2/75  Skoda.pc'
  RM.takeGarageCar('BWR_Pro_2', PC, true)
  check(#calls == 1 and calls[1].how == 'replace',
    'Take REPLACES the car the driver is in, which has no vehicle-count limit')
  check(calls[1].model == 'BWR_Pro_2' and calls[1].config == PC,
    'and hands BeamNG the model and the .pc path verbatim, spaces and all: the '
      .. 'engine resolves the file, this does not')

  calls = {}
  RM.takeGarageCar('BWR_Pro_2', PC, false)
  check(#calls == 1 and calls[1].how == 'spawn',
    'and asking for an extra car goes to spawnNewVehicle instead')

  -- An entry with no saved config behind it must never reach the engine: with
  -- no config BeamNG spawns the model's DEFAULT, which is a different car
  -- wearing the approved car's name.
  calls = {}
  clearLog()
  RM.takeGarageCar('BWR_Pro_2', '', true)
  check(#calls == 0, 'an entry with no saved config is refused rather than '
    .. 'spawning the models default and calling it the approved car')
  check(refusal() ~= nil, 'and the driver is told why')

  calls = {}
  RM.takeGarageCar('', PC, true)
  check(#calls == 0, 'and a missing model is refused too')

  -- A build without the spawn API must not raise: the panel offers the button
  -- from a server broadcast, and the client may be anything.
  calls = {}
  core_vehicles = { removeCurrent = function () end }
  local ok = pcall(RM.takeGarageCar, 'BWR_Pro_2', PC, true)
  check(ok, 'a build with no spawn API is reported, not an error thrown through the UI')

  core_vehicles = realCV
end

print(string.format('garage_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
