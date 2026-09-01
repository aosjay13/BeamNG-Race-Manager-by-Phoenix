-- Headless test for the way this mod TOUCHES A VEHICLE, which is always
-- through a pcall, and always with the method lookup INSIDE it.
-- Run from the repo root: lua tests/vehicle_access_test.lua
--
-- Why this file exists, and it is a mistake worth keeping a test for.
--
-- Every vehicle call in raceManager.lua is wrapped, because a car can be
-- deleted between the frame that found it and the frame that asks it something:
-- a driver respawning, a BeamMP player leaving, an admin clearing the field.
-- The wrapper is written as
--
--     pcall(function () return veh:getID() end)
--
-- and that closure looks like pure waste. It is one allocation per call, on a
-- path that runs per frame per car, and the obvious rewrite is
--
--     pcall(veh.getID, veh)
--
-- which is the documented idiom for calling a method under pcall without
-- building a closure. It was applied here in the name of allocation count, with
-- a comment claiming "same protection, no garbage".
--
-- IT IS NOT THE SAME PROTECTION. `veh.getID` is an INDEX on the vehicle, and a
-- BeamNG vehicle is userdata whose __index is a binding function rather than a
-- plain table. As an ARGUMENT it is evaluated before pcall is ever called, so
-- when the index is the thing that raises -- which is exactly what a dangling
-- object does -- the error is thrown in the caller's own frame and the pcall
-- never sees it. The closure moves the index inside the protected call, which is
-- the entire reason it is written that way.
--
-- The difference is invisible to every other test in this repo, because they all
-- stub `veh` as a plain Lua table whose index can never fail. So it is pinned
-- here instead, against an object that behaves like the real thing.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- A stand-in for a BeamNG vehicle: __index is a FUNCTION, as the engine's
-- bindings make it, so indexing is a call that can fail on its own.
local function vehicle(state)
  return setmetatable({}, { __index = function (_, k)
    if state == 'dangling' then
      -- What a deleted object does: the lookup itself raises.
      error('attempt to use a deleted vehicle', 0)
    end
    if state == 'alive' and k == 'getID' then
      return function () return 7 end
    end
    return nil        -- 'stripped': a live object missing the method
  end })
end

-- The form the extension uses.
local function guarded(veh)
  local ok, id = pcall(function () return veh:getID() end)
  if ok then return id end
  return nil
end

-- The rewrite that looks equivalent.
local function unguarded(veh)
  local ok, id = pcall(veh.getID, veh)
  if ok then return id end
  return nil
end

-- ---------------------------------------------------------------------------
-- A live vehicle: both forms agree, which is why the rewrite looks safe
-- ---------------------------------------------------------------------------
check(guarded(vehicle('alive')) == 7, 'a live vehicle reports its id')
local ok, got = pcall(unguarded, vehicle('alive'))
check(ok and got == 7,
  'and the argument form agrees on a live vehicle, which is the whole trap')

-- ---------------------------------------------------------------------------
-- A vehicle with no such method: both still agree
-- ---------------------------------------------------------------------------
check(guarded(vehicle('stripped')) == nil,
  'a vehicle without getID reports nil rather than raising')
ok = pcall(unguarded, vehicle('stripped'))
check(ok, 'and the argument form survives that too: the index returned nil')

-- ---------------------------------------------------------------------------
-- THE CASE THE pcall EXISTS FOR: an object whose INDEX raises
-- ---------------------------------------------------------------------------
-- This is a car deleted out from under a walk that is midway through it. The
-- guarded form has to answer nil; anything that throws here takes the update
-- loop, the draw pass or an admin button down with it.
local danglingOk, danglingResult = pcall(guarded, vehicle('dangling'))
check(danglingOk,
  'a dangling vehicle does NOT escape the pcall: this is the whole contract')
check(danglingOk and danglingResult == nil,
  'and it answers nil, so the caller can carry on without it')

-- ...and the proof that the rewrite breaks it, so nobody re-applies it.
local rewriteOk = pcall(unguarded, vehicle('dangling'))
check(not rewriteOk,
  'pcall(veh.getID, veh) THROWS on a dangling vehicle: the index is an '
    .. 'argument, so it runs before pcall and outside its protection. If this '
    .. 'check ever fails, Lua changed and the closure may be revisited')

-- ---------------------------------------------------------------------------
-- The source itself, so the fix cannot be quietly undone
-- ---------------------------------------------------------------------------
local f = assert(io.open('lua/ge/extensions/raceManager.lua', 'r'))
local src = f:read('*a')
f:close()

-- Strip comments before searching: this file's own explanation names the unsafe
-- form, and a test that reads its own warning as the bug is worse than useless.
local code = src:gsub('%-%-[^\n]*', '')

check(not code:find('pcall(veh.getID', 1, true),
  'no live call site uses pcall(veh.getID, veh): the method lookup must be '
    .. 'inside the closure, not evaluated as an argument')
check(not code:find('pcall(veh.setMeshAlpha', 1, true),
  'and the ghost fade uses the closure form for the same reason')

local guardedCalls = select(2, code:gsub('pcall%(function %(%) return veh:getID%(%) end%)', ''))
check(guardedCalls >= 3, string.format(
  'the three vehicle-id lookups (vehicleId and both forEachVehicle branches) '
    .. 'are all guarded; found %d', guardedCalls))

print(string.format('vehicle_access_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
