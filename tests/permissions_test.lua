-- Headless test for THE TWO PERMISSION TIERS.
--
-- A league hands its race directors a password so somebody other than the owner
-- can run a Tuesday night. Before this split that password was the whole of the
-- security model: whoever could start a race could also rotate the master
-- password, wipe every results file on the server and delete a layout that took
-- an evening to drive. Three things, none of them undoable, all of them one
-- mis-click away from a control sitting in the same panel as Log out.
--
-- So there are two tiers now, and this file is about the LINE between them
-- rather than about either one working. Each property below has a way of being
-- got wrong that looks fine in the panel and fails on a race night:
--
--   * A ROLE STRING IS NOT `true`. isAuthenticated compared against the boolean
--     the table used to hold. A role is truthy but is not `true`, so leaving
--     that comparison alone refuses every command from everybody -- the whole
--     mod dead, behind a login that says it worked.
--
--   * A REFUSAL ON THE TIER IS NOT A REFUSAL ON THE LOGIN. The obvious way to
--     say no reuses RM_LoginResult, and that event carries the client's admin
--     flag: a moderator pressing an admin-only button would be logged out of a
--     session they are entitled to, mid evening, with no clue why.
--
--   * AN EMPTY MODERATOR PASSWORD IS THE OFF SWITCH, so it must never match --
--     including when the login box was submitted blank, which is exactly what
--     a plain `pass == moderatorPassword` says yes to. That is an anonymous
--     full moderator login on every server that never set one.
--
--   * AN EMPTY ADMIN PASSWORD IS NOT AN OFF SWITCH. There is no way back from
--     it short of editing config.json by hand, so it is refused.
--
--   * THE TIER SURVIVES A RESTART, or an owner sets a moderator password on
--     Tuesday and finds their directors locked out on Wednesday.
--
-- Run from the repo root: lua5.3 tests/permissions_test.lua

local DATA = 'Resources/Server/RaceManager/Data'

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a'); f:close(); return s
end

removeTree('Resources')

-- pid 1 is the owner, pid 2 the race director, pid 3 somebody who never logs in.
local connected = { [1] = 'Owner', [2] = 'Director', [3] = 'Driver' }
local currentMap = 'gridmap_v2'
local sent = {}        -- every TriggerClientEvent, in order
local chat = {}        -- every SendChatMessage, in order

local function lastOf(event, target)
  for i = #sent, 1, -1 do
    if sent[i].event == event and (target == nil or sent[i].target == target) then
      return sent[i].payload
    end
  end
  return nil
end
local function countOf(event, target)
  local n = 0
  for _, s in ipairs(sent) do
    if s.event == event and (target == nil or s.target == target) then n = n + 1 end
  end
  return n
end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    sent[#sent + 1] = { target = target, event = event, payload = payload }
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/' .. currentMap .. '/info.json' end,
}

-- The plugin encodes with Util.JsonEncode and decodes with Util.JsonDecode, and
-- the tests read those payloads back. Encoding to the table itself keeps the
-- read side honest without a second JSON implementation in this file; the
-- decoder only has to cope with the flat objects the tests send in.
Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    if type(s) ~= 'string' then error('json: not a string', 0) end
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    local f = load('return ' .. body)
    if not f then error('json: parse failed', 0) end
    return f()
  end,
}

local function boot()
  sent, chat = {}, {}
  dofile('server/RaceManager/main.lua')
  onInit()
  RM_onPlayerJoin(1)
  RM_onPlayerJoin(2)
  RM_onPlayerJoin(3)
end

local function login(pid, password)
  RM_onLogin(pid, '{"password":"' .. password .. '"}')
  return lastOf('RM_LoginResult', pid) or {}
end

boot()

-- ---------------------------------------------------------------------------
-- 1. The shipped state: one password, one tier. Nothing has changed for a
--    server that never asks for the second one.
-- ---------------------------------------------------------------------------
local ownerLogin = login(1, 'phoenix')
check(ownerLogin.success == true, 'the admin password logs in')
check(ownerLogin.role == 'admin',
  'and the reply says which tier it bought, so the panel need not guess')

-- THE ONE THAT KILLS THE WHOLE MOD. isAuthenticated compared against `true`
-- while the table held booleans; it holds a role string now.
RM_onSetTotalLaps(1, '{"laps":7}')
check(lastOf('RM_Update', -1).totalLaps == 7,
  'an ordinary admin command still works: a role string is truthy but is not '
    .. '`true`, and a stale comparison there refuses every command from everybody')

check(login(2, 'phoenix').success == true, 'two sessions can hold the admin password at once')
RM_onLogout(2)

-- ---------------------------------------------------------------------------
-- 2. The moderator tier is OFF until somebody sets it, and an empty password is
--    not what opens it.
-- ---------------------------------------------------------------------------
check(login(2, 'wrong').success == false, 'a wrong password is refused')
check(lastOf('RM_LoginResult', 2).role == nil, 'and buys no tier at all')

-- Submitting the login box empty is the case a plain string compare says yes
-- to, because the unset moderator password is also empty.
check(login(2, '').success == false,
  'a BLANK password is refused: the unset moderator password is empty too, and '
    .. 'a plain compare would hand the tier to anyone who pressed Login')

-- ---------------------------------------------------------------------------
-- 3. An admin sets one, and it grants the narrower tier.
-- ---------------------------------------------------------------------------
RM_onChangePassword(1, '{"password":"tuesday","role":"moderator"}')
local pwNote = lastOf('RM_PasswordChanged', -1)
check(pwNote and pwNote.role == 'moderator',
  'the change notice says WHICH password moved: there are two of them now')
check(pwNote and pwNote.cleared == false, 'and that this one was set rather than cleared')

local modLogin = login(2, 'tuesday')
check(modLogin.success == true, 'the moderator password logs in')
check(modLogin.role == 'moderator', 'at the moderator tier')
check(login(1, 'phoenix').role == 'admin',
  'and the admin password still buys the full tier alongside it')

-- The state a client reads its own tier off. Targeted sends only.
RM_onRequestState(2)
local modState = lastOf('RM_Update', 2)
check(modState.youAreAdmin == true,
  'a moderator reads as an admin on the flag every ordinary control is gated '
    .. 'on: running the night is what both tiers are for')
check(modState.youRole == 'moderator', 'and the tier rides alongside it')
RM_onRequestState(1)
check(lastOf('RM_Update', 1).youRole == 'admin', 'the owner reads as the full tier')

-- ---------------------------------------------------------------------------
-- 4. What a moderator CAN do: everything about running a night.
-- ---------------------------------------------------------------------------
RM_onSetTotalLaps(2, '{"laps":12}')
check(lastOf('RM_Update', -1).totalLaps == 12, 'a moderator sets the race distance')
RM_onSetMaxResets(2, '{"maxResets":3}')
check(lastOf('RM_Update', -1).maxResets == 3, 'and the reset allowance')
RM_onStartQualifying(2)
check(lastOf('RM_Update', -1).phase ~= 'waiting', 'and starts a session')
RM_onEndRace(2)

-- ---------------------------------------------------------------------------
-- 5. What a moderator CANNOT do, and HOW it is refused. The refusal must not
--    ride RM_LoginResult: that event carries the admin flag, so answering down
--    it logs the moderator out of a session they are entitled to.
-- ---------------------------------------------------------------------------
local loginsBefore = countOf('RM_LoginResult', 2)

RM_onChangePassword(2, '{"password":"mine","role":"admin"}')
check(countOf('RM_Denied', 2) == 1, 'a moderator changing the admin password is refused')
check(countOf('RM_LoginResult', 2) == loginsBefore,
  'and the refusal does NOT ride RM_LoginResult, which would log them out of a '
    .. 'session they are entitled to, mid race night, for pressing a button')
check(login(2, 'mine').success == false, 'and the admin password really did not move')
login(2, 'tuesday')

RM_onChangePassword(2, '{"password":"theirs","role":"moderator"}')
check(login(2, 'theirs').success == false,
  'nor can a moderator set the MODERATOR password: that is handing out their '
    .. 'own tier, which makes the split decorative')
login(2, 'tuesday')

-- Clearing the server results. The only record a league has of a race night.
local deniedBefore = countOf('RM_Denied', 2)
RM_onClearResults(2)
check(countOf('RM_Denied', 2) == deniedBefore + 1,
  'a moderator cannot clear the server results cache')

-- ---------------------------------------------------------------------------
-- 6. Layouts. Saving is a moderator's job; deleting is not.
-- ---------------------------------------------------------------------------
local function gate(x) return '{"x":' .. x .. ',"y":0,"z":0,"hx":0,"hy":1}' end
RM_onSaveLayout(2, '{"name":"Club","checkpoints":[' .. gate(10) .. ',' .. gate(20) .. ']}')
RM_onRequestLayouts(2)
check(#lastOf('RM_Layouts', 2).layouts == 1,
  'a moderator SAVES a layout: that is building a track, and it is their job')

deniedBefore = countOf('RM_Denied', 2)
RM_onDeleteLayout(2, '{"name":"Club"}')
check(countOf('RM_Denied', 2) == deniedBefore + 1, 'a moderator cannot DELETE one')
RM_onRequestLayouts(2)
check(#lastOf('RM_Layouts', 2).layouts == 1, 'and the layout is still there')

-- The derby arena store has the same shape and gets the same guard.
RM_onDerbySaveLayout(2, '{"name":"Bowl","boundary":[{"x":0,"y":0,"z":0},'
  .. '{"x":10,"y":0,"z":0},{"x":10,"y":10,"z":0}]}')
deniedBefore = countOf('RM_Denied', 2)
RM_onDerbyDeleteLayout(2, '{"name":"Bowl"}')
check(countOf('RM_Denied', 2) == deniedBefore + 1,
  'nor delete a derby arena: same irreversible thing, same guard')

-- ---------------------------------------------------------------------------
-- 6b. Garage sets. A set is a whole field captured car by car, so deleting one
--     joins the admin-only three. Clearing the LIVE list does not: any saved
--     set puts it straight back, which is the difference the line is drawn on.
-- ---------------------------------------------------------------------------
local function garageSets()
  RM_onRequestState(2)
  return lastOf('RM_Update', 2).garageSets or {}
end
local function hasSet(name)
  for _, s in ipairs(garageSets()) do if s == name then return true end end
  return false
end

RM_onSetGarageEnforce(2, '{"enabled":false}')
RM_onWhitelistVehicle(2, '{"model":"covet","label":"Club Car",'
  .. '"sig":"model=covet|parts=body=covet_body|vars=camber=0.0000"}')
RM_onSaveGarageSet(2, '{"name":"Club Night"}')
check(hasSet('Club Night'), 'a moderator SAVES a garage set: that is building a field')

deniedBefore = countOf('RM_Denied', 2)
RM_onDeleteGarageSet(2, '{"name":"Club Night"}')
check(countOf('RM_Denied', 2) == deniedBefore + 1, 'but cannot DELETE one')
check(hasSet('Club Night'), 'and the set is still there')

-- Clearing the live list stays theirs. It empties what is loaded, and the set
-- above reloads it.
deniedBefore = countOf('RM_Denied', 2)
RM_onClearGarage(2)
check(countOf('RM_Denied', 2) == deniedBefore,
  'clearing the LIVE garage list is still a moderator job: a saved set puts it '
    .. 'straight back, so nothing is lost')
check(#lastOf('RM_Update', -1).garage == 0, 'and it really did clear')

RM_onDeleteGarageSet(1, '{"name":"Club Night"}')
check(not hasSet('Club Night'), 'an admin deletes it')

-- ---------------------------------------------------------------------------
-- 7. The admin can do all three, or the tier is a wall rather than a door.
-- ---------------------------------------------------------------------------
RM_onDeleteLayout(1, '{"name":"Club"}')
RM_onRequestLayouts(1)
check(#lastOf('RM_Layouts', 1).layouts == 0, 'an admin deletes the layout')
check(countOf('RM_Denied', 1) == 0, 'and is never refused on the tier')

RM_onClearResults(1)
check(chat[#chat]:find('Results cache cleared', 1, true) ~= nil,
  'and clears the server results cache')

-- ---------------------------------------------------------------------------
-- 8. Somebody who never logged in at all gets the LAPSED reply, not the tier
--    refusal: their login really has gone, and the panel has to be told so it
--    can offer the login box back.
-- ---------------------------------------------------------------------------
RM_onClearResults(3)
check(countOf('RM_Denied', 3) == 0, 'a stranger gets no tier refusal')
local stranger = lastOf('RM_LoginResult', 3)
check(stranger and stranger.success == false and stranger.lapsed == true,
  'they are told their login has lapsed instead, which is what brings the login '
    .. 'box back rather than leaving them pressing dead buttons')

-- ---------------------------------------------------------------------------
-- 9. Persistence. An owner who sets a moderator password on Tuesday must not
--    find their directors locked out on Wednesday.
-- ---------------------------------------------------------------------------
local cfg = readFile(DATA .. '/config.json')
check(cfg and cfg:find('moderatorPassword', 1, true) ~= nil,
  'the moderator password is written to config.json')
check(cfg and cfg:find('tuesday', 1, true) ~= nil, 'with the value that was set')

boot()
check(login(2, 'tuesday').role == 'moderator',
  'and it still opens the moderator tier after a restart')
check(login(1, 'phoenix').role == 'admin', 'alongside the admin password')

-- ---------------------------------------------------------------------------
-- 10. Turning the tier off again, and the one password that may not be emptied.
-- ---------------------------------------------------------------------------
-- Signed in as a moderator at the moment the tier is switched off.
login(2, 'tuesday')
RM_onChangePassword(1, '{"password":"","role":"moderator"}')
check(lastOf('RM_PasswordChanged', -1).cleared == true,
  'an empty moderator password is a real setting, not a blank field to ignore')

-- A ROTATION leaves everyone logged in, on purpose: an admin changing the
-- password mid evening must not boot the director out of the race they are
-- running. Emptying it is not a rotation, it is "this tier should not exist",
-- and a session left signed in at a tier that no longer exists is the one
-- reading of that nobody meant.
local kicked = lastOf('RM_LoginResult', 2)
check(kicked and kicked.success == false and kicked.lapsed == true,
  'a moderator signed in when the tier is turned off is signed out, and told '
    .. 'their login lapsed rather than left pressing dead buttons')
deniedBefore = countOf('RM_Denied', 2)
RM_onSetTotalLaps(2, '{"laps":4}')
check(lastOf('RM_Update', -1).totalLaps ~= 4, 'and their commands stop working')
check(countOf('RM_Denied', 2) == deniedBefore, 'refused as lapsed, not on the tier')

check(login(2, 'tuesday').success == false, 'the old moderator password stops working')
check(login(2, '').success == false,
  'and an empty login does not inherit the tier it just turned off')

RM_onChangePassword(1, '{"password":""}')
check(login(1, 'phoenix').role == 'admin',
  'an EMPTY ADMIN password is refused: there is no way back from it short of '
    .. 'editing config.json by hand, so the owner keeps the one they had')

-- ---------------------------------------------------------------------------
-- 11. Two passwords set to the same string. The higher tier has to win, or an
--     owner who reused their password quietly demotes themselves.
-- ---------------------------------------------------------------------------
RM_onChangePassword(1, '{"password":"phoenix","role":"moderator"}')
check(login(2, 'phoenix').role == 'admin',
  'with both passwords identical the ADMIN tier is granted, not the moderator one')

-- ---------------------------------------------------------------------------
-- 12. Logging out drops the tier with the session.
-- ---------------------------------------------------------------------------
RM_onLogout(2)
deniedBefore = countOf('RM_Denied', 2)
RM_onSetTotalLaps(2, '{"laps":3}')
check(lastOf('RM_Update', -1).totalLaps ~= 3, 'a logged-out session runs nothing')
check(countOf('RM_Denied', 2) == deniedBefore, 'and is refused as lapsed, not on the tier')

removeTree('Resources')

if fails == 0 then
  io.stdout:write(('permissions_test: %d checks, 0 failures\n'):format(checks))
else
  io.stdout:write(('permissions_test: %d FAILURES of %d checks\n'):format(fails, checks))
  os.exit(1)
end
