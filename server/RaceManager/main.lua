-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative session state machine for circuit racing:
--
--   waiting -> qualifying -> grid -> countdown -> racing -> finished
--                 (quali)   (grid locked)          (race)
--
-- Qualifying: clients time their own laps (the server has no physics access)
-- and report each completed lap; the server keeps the Best Lap per driver.
-- Generate Grid sorts drivers fastest-to-slowest by quali Best Lap and locks
-- in starting positions. Race mode shows the grid, then the countdown starts
-- the race. During the race clients report every completed lap; the server
-- tracks Current Lap, race Best Lap, Laps Led (first driver to complete each
-- lap), and flags the finish when a driver completes the configured lap count.
-- All timing that must be fair across drivers (finish order, laps led) is
-- decided by arrival order / the server clock.
--
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TICK_MS            = 100   -- server clock resolution
-- Broadcast cadence while racing. This is also the live-position refresh rate:
-- every push re-sorts the running order and re-stamps each driver's position,
-- so 3 ticks (~300 ms) keeps the leaderboard lively without flooding clients.
local PUSH_EVERY_TICKS   = 3
local COUNTDOWN_FROM     = 3     -- 3, 2, 1, GO!
local DEFAULT_TOTAL_LAPS = 5
local MAX_TOTAL_LAPS     = 500
-- League regulations. Resets: -1 means unlimited (the historical behaviour and
-- the default), 0 forbids resets outright, N allows N per session.
local UNLIMITED_RESETS   = -1
local MAX_RESET_LIMIT    = 99

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  phase        = 'waiting',  -- waiting | grid | countdown | qualifying | racing | finished
  -- Which session the lifecycle is currently running. There is ONE lifecycle --
  -- form the grid, hold, GO, remove finished cars, respawn everybody -- and this
  -- is the only thing that differs between a race and a qualifying session:
  -- which lap count they run to and how a completed lap is scored. Qualifying
  -- used to sit outside the state machine with lap detection of its own, which
  -- is why a 3-lap qualifying session took five or six laps to finish.
  sessionKind  = 'race',     -- race | quali
  time         = 0.0,        -- seconds since GO (advanced by RM_Tick while a session runs)
  totalLaps    = DEFAULT_TOTAL_LAPS,
  maxResets    = UNLIMITED_RESETS,  -- vehicle resets allowed per driver per session
  resetMode    = 'inplace',  -- what a legal reset does: 'inplace' | 'checkpoint'
  jokerEnabled = false,      -- rallycross joker lap required exactly once per race
  -- Race entry. 'join' (default): drivers opt in with the UI's Join Race button
  -- and only they are gridded. 'all': every connected session is a participant,
  -- which is how the plugin behaved before entry lists existed.
  entryMode    = 'join',
  -- Starting grid. gridMode decides how the slots are filled:
  --   quali  -- fastest qualifying lap first (the classic behaviour)
  --   random -- a random draw, for when no qualifying was run
  --   custom -- the order the admin set by hand (RM_SetDriverGrid)
  gridMode     = 'quali',
  startSlots   = 0,          -- start positions the loaded track layout has
  -- Qualifying session rules.
  ghostQuali     = false,    -- rivals are ghosts during qualifying
  qualiLapLimit  = 0,        -- timed laps allowed per driver (0 = unlimited)
  qualiTimeLimit = 0,        -- seconds the session runs for (0 = unlimited)
  qualiTime      = 0.0,      -- seconds elapsed in the current quali session
  -- Post-expiry state for a TIMED session, and the one piece of the lifecycle a
  -- lap-limited session has no equivalent of.
  --
  -- A lap-limited session has a per-driver terminal event built in: the
  -- crossing that completes their allowance is the moment they are done, and the
  -- session ends when the last of them is. A timed session has no such thing --
  -- the clock expires for everybody at once, while they are spread around the
  -- circuit -- so expiry cannot simply end it. Standing everyone down where they
  -- are would throw away the lap they are on, which in qualifying is the one
  -- that matters most.
  --
  -- So expiry does not end the session, it changes what a crossing MEANS: while
  -- this is set, the next start/finish line a driver crosses is terminal for
  -- them rather than the start of another lap. That reuses the removal and the
  -- respawn-all the lap-limited path already goes through, and it is why this is
  -- a sub-state of the running phase rather than a phase of its own -- drivers
  -- must stay controllable and on track, which is exactly what the running phase
  -- already gives them.
  finalLap       = false,
  finalLapLeft   = 0,        -- seconds of grace left before the stragglers are
                             -- taken where they stand (see FINAL_LAP_GRACE)
}
local players = {}          -- [playerID] = per-player record
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'
local lapFirsts = {}        -- [lapNumber] = pid of the first driver to complete that lap
local MAX_QUALI_LAPS   = 99
local MAX_QUALI_TIME   = 7200   -- seconds (2 h)
-- How long a timed session waits, after the clock expires, for drivers still out
-- there to come round and take the flag. A driver sitting in the pits, parked,
-- or who never left the grid has no crossing to give, and without a bound the
-- session would wait for them forever. Sized to comfortably clear one lap of a
-- long circuit; when it runs out the stragglers are taken where they stand and
-- the session closes normally.
local FINAL_LAP_GRACE  = 180    -- seconds

-- ---------------------------------------------------------------------------
-- Admin authentication
-- ---------------------------------------------------------------------------
-- BeamMP guest account IDs rotate constantly, so admin rights are gated by a
-- shared password rather than a name/ID whitelist. A player sends RM_Login with
-- the current master password; on a match their session ID is recorded in
-- authenticatedPlayers and every admin-level event checks that table before
-- acting. The default below is meant to be rotated on the fly (RM_ChangePassword)
-- once an admin is logged in -- change it before the first public session.
local DEFAULT_ADMIN_PASSWORD = 'phoenix'
local adminPassword = DEFAULT_ADMIN_PASSWORD
local authenticatedPlayers = {}   -- [playerID] = true while that session is an admin

local function isAuthenticated(pid)
  return authenticatedPlayers[pid] == true
end

-- Guard placed at the top of every admin-level event handler. Any command from
-- a session that has not logged in is dropped (and logged so it's diagnosable).
local function requireAuth(pid)
  if authenticatedPlayers[pid] then return true end
  print('[RaceManager] Ignored admin command from unauthenticated player ' .. tostring(pid))
  return false
end

local function newRecord(pid)
  return {
    id         = pid,
    name       = MP.GetPlayerName(pid) or ('Player ' .. pid),
    -- Admin-assigned readable name. Display only, cleared when the connection
    -- is inherited by someone else. nil = show the real name.
    alias      = nil,
    -- waiting | qualifying | gridded | racing | finished | dsq | dnf
    status     = 'waiting',
    joined     = false,      -- opted into the race (see race.entryMode)
    gridPos    = nil,        -- locked-in starting position (Generate Grid)
    customGrid = nil,        -- slot the admin pinned this driver to (custom mode)
    qualiBest  = nil,        -- best qualifying lap (seconds)
    qualiLaps  = 0,          -- timed qualifying laps completed this session
    raceBest   = nil,        -- best race lap (seconds)
    currentLap = 0,          -- lap the driver is currently on (1-based once racing)
    lapsLed    = 0,          -- laps this driver crossed the line first on
    finishTime = nil,        -- server race clock at final-lap completion
    resets     = 0,          -- vehicle resets consumed this session
    resetsBlocked = 0,       -- resets refused after the allowance ran out
    jokerTaken = 0,          -- completed runs of the joker route this race
    jokerLap   = nil,        -- lap the joker route was taken on
    outReason  = nil,        -- why this driver is dnf/dsq (results + UI text)
    -- Live position tracking (see the "Running order" section below).
    position   = nil,        -- current place in the running order (1 = leader)
    cpCleared  = 0,          -- checkpoints passed on the current lap
    distNext   = nil,        -- metres from the car to the next checkpoint centre
  }
end

-- Telemetry reported by a client is only meaningful while that driver is
-- circulating; wipe it whenever their lap state restarts so a stale distance
-- can never decide a position.
local function clearProgress(rec)
  rec.cpCleared = 0
  rec.distNext  = nil
end

-- ---------------------------------------------------------------------------
-- Display aliases (presentation only -- NEVER a key)
-- ---------------------------------------------------------------------------
-- Everyone on this server is a BeamMP guest, so there is no stable per-player
-- identity to bind a readable name to: the session id is recycled between
-- players (see RM_onPlayerDisconnect) and the guest name is regenerated on every
-- join. An alias is therefore scoped to the connection and lives ON THE PLAYER
-- RECORD, not in a side table keyed by session id -- a side table would hand a
-- departed player's alias to whoever inherits that id next.
--
-- Nothing here is ever used as a lookup key. Race logic keys on the BeamMP
-- player id throughout (players[pid], rec.id, the client's own-row match); the
-- alias is read only by displayName below, which feeds the results file, the
-- chat announcements and the leaderboard payload.
local MIN_ALIAS_LEN = 3
local MAX_ALIAS_LEN = 20    -- results file pads the Driver column to 22
-- Names nobody may take, so a player cannot pose as staff or as an unnamed
-- player. Compared case-insensitively.
local RESERVED_ALIASES = {
  ['admin'] = true, ['server'] = true, ['host'] = true, ['console'] = true,
  ['system'] = true, ['racemanager'] = true, ['race manager'] = true,
}

-- Alias for any record that carries a player id, or nil.
--
-- The derby keeps its OWN player table with its own copy of the name, and an
-- alias is only ever set on the racing record -- that is the one place an admin
-- can reach. Rather than keeping a second copy that can drift, a record with no
-- alias of its own resolves through the racing record by id. That also means
-- setting or clearing a name mid-derby is picked up immediately.
local function aliasOf(rec)
  if not rec then return nil end
  if rec.alias then return rec.alias end
  local owner = rec.id and players[rec.id]
  return owner and owner.alias or nil
end

-- The single resolution point on this side: alias if set, real name otherwise.
-- rec.name always exists (newRecord falls back to 'Player <id>'), so this can
-- never return nil or an empty string.
local function displayName(rec)
  if not rec then return '?' end
  return aliasOf(rec) or rec.name
end

-- Cleaned alias, or nil plus a reason to show the admin.
--
-- ASCII only, and that is deliberate rather than lazy: the results file formats
-- fixed-width columns with %-22s, and Lua pads by BYTES, not codepoints, so a
-- single multi-byte character silently breaks the alignment of every row after
-- it. The character class also excludes control characters and anything that
-- could read as markup.
local function sanitizeAlias(raw)
  if type(raw) ~= 'string' then return nil, 'not a string' end
  local s = raw:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
  if s == '' then return nil, 'empty' end
  if s:find('[^%w %-%_%.]') then
    return nil, 'letters, digits, spaces and - _ . only'
  end
  if #s < MIN_ALIAS_LEN then return nil, 'at least ' .. MIN_ALIAS_LEN .. ' characters' end
  if #s > MAX_ALIAS_LEN then return nil, 'at most ' .. MAX_ALIAS_LEN .. ' characters' end
  local lower = s:lower()
  if RESERVED_ALIASES[lower] then return nil, '"' .. s .. '" is reserved' end
  if lower:find('^guest') then return nil, 'cannot start with "guest"' end
  return s
end

-- Rejects a name already held by somebody else, as an alias OR as their real
-- guest name, so an alias can never shadow another driver on the timing screen.
local function aliasInUse(candidate, exceptPid)
  local lower = candidate:lower()
  for pid, rec in pairs(players) do
    if pid ~= exceptPid then
      if rec.alias and rec.alias:lower() == lower then return true, rec end
      if rec.name  and rec.name:lower()  == lower then return true, rec end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Player identity registry
-- ---------------------------------------------------------------------------
-- `players` is a PER-SESSION table. Start Qualifying and Reset Session rebuild
-- it from scratch on purpose -- lap times, grid slots and reset tallies are all
-- meant to be thrown away with the session. Two things on that record are not:
-- the admin-assigned display name, and the driver's decision to enter. Wiping
-- the table took both with it every time, which is exactly why names vanished
-- between qualifying and the race, and again between one race and the next.
--
-- They live here instead. Keyed by BeamMP player id, because that is the key
-- everything else in this file already uses -- and NOT by anything derived from
-- a vehicle: a vehicle id changes on every respawn, so a name bound to one
-- survives nothing. The id on its own is not an identity either (BeamMP
-- recycles session ids between players), so an entry is only handed back when
-- the CONNECTION still matches: same id AND same guest name. A different player
-- inheriting the id starts clean, which is what stops an accidental
-- impersonation.
local identities = {}   -- [pid] = { name = <guest name>, alias = ..., joined = bool }

-- Every player id that reaches this file goes through here first.
--
-- Event handlers are called with a number, but MP.GetPlayers() keys its map on
-- the server's own terms, and a key that does not compare equal to the one a
-- record was stored under reads as "that player is not on this server". That is
-- how a full grid of drivers who had every one of them opted in came out as an
-- empty entry list: the online check purged every record, and with it every
-- `joined` flag, a moment before the grid was built from them.
local function pidKey(id)
  local n = tonumber(id)
  if not n then return nil end
  return math.floor(n)
end

-- Connected players, keyed exactly the way every record in `players` is.
local function onlinePlayers()
  local out = {}
  local raw = MP.GetPlayers()
  if type(raw) ~= 'table' then return out end
  for id, name in pairs(raw) do
    local key = pidKey(id)
    if key then
      out[key] = name or MP.GetPlayerName(key) or ('Player ' .. key)
    end
  end
  return out
end

-- The stored identity for this connection, or nil. Clears itself when the name
-- no longer matches: that means somebody else now holds the session id.
local function identityFor(pid, name)
  local ident = identities[pid]
  if not ident then return nil end
  if name and ident.name and ident.name ~= name then
    if ident.alias then
      print(string.format('[RaceManager] Session id %d reused (%s -> %s): display name "%s" dropped',
        pid, tostring(ident.name), tostring(name), ident.alias))
    end
    identities[pid] = nil
    return nil
  end
  return ident
end

-- Write the durable half of a record back to the registry. Called from every
-- place that can change a display name or an entry decision, so the registry is
-- never behind the record it mirrors.
local function rememberIdentity(rec)
  if not rec or not rec.id then return end
  identities[rec.id] = {
    name   = rec.name,
    alias  = rec.alias,
    joined = rec.joined == true,
  }
end

-- Stand the whole field down. Reset Session is the "start the evening again"
-- button, so the entry list goes with it -- but the display names do NOT: an
-- admin who spent five minutes naming a grid should not have to do it twice
-- because they cleared a leaderboard.
local function clearEntries()
  for _, ident in pairs(identities) do
    ident.joined = false
  end
end

local function ensurePlayer(pid)
  pid = pidKey(pid)
  if not pid then return nil end
  if not players[pid] then
    local rec = newRecord(pid)
    -- A fresh record for a connection we already know inherits its display name
    -- and its entry decision. This is the whole point of the registry: the
    -- record is disposable, the identity is not.
    local ident = identityFor(pid, rec.name)
    if ident then
      rec.alias  = ident.alias
      rec.joined = ident.joined == true
    end
    players[pid] = rec
    rememberIdentity(rec)
  end
  return players[pid]
end

-- Forward declaration: the derby module lives further down the file, but its
-- entrant count is DERIVED from the racing entry list below (opt-in derbies
-- honour the same Join Race). So anything that changes who is entered has to
-- refresh the derby panel too, or an admin watching it reads a stale field size
-- and presses Start Derby expecting a different set of drivers. Same pattern
-- the garage store uses to be reachable from the state broadcast above it.
local derbyEntryListChanged

-- ---------------------------------------------------------------------------
-- Race entry list
-- ---------------------------------------------------------------------------
-- Nothing below assumes "connected == racing". A driver is a participant when
-- they opted in, or when the admin put the server in 'all' mode (which is what
-- the plugin used to do implicitly for everyone).
local function isEntrant(rec)
  if not rec then return false end
  if race.entryMode == 'all' then return true end
  return rec.joined == true
end

local function entrantCount()
  local n = 0
  for _, rec in pairs(players) do
    if isEntrant(rec) then n = n + 1 end
  end
  return n
end

local function decodeNumber(rawData, field)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local n = tonumber(data[field])
  return n
end

local function decodeString(rawData, field)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local v = data[field]
  if v == nil then return nil end
  return tostring(v)
end

-- ---------------------------------------------------------------------------
-- Running order (live positions)
-- ---------------------------------------------------------------------------
-- Classification bucket shared by the live table and the results export:
-- classified finishers first, then drivers still out on track, then drivers
-- excluded by the regulations (joker ruling), then DNFs.
local function classRank(rec)
  if rec.status == 'dnf' then return 3 end
  if rec.status == 'dsq' then return 2 end
  if rec.finishTime then return 0 end
  return 1
end

-- The live running order between two drivers who are still circulating is
-- decided by three metrics, in this exact order:
--
--   1. Laps completed        -- more laps is ahead. Taken from the SERVER's own
--                               lap counter (RM_onLap), never from the client
--                               telemetry, so a client cannot invent a lap.
--   2. Checkpoints cleared   -- on the current lap; more gates passed is ahead.
--   3. Distance to the next  -- metres from the car to the next checkpoint's
--      checkpoint               centre, measured client-side (the server has no
--                               physics access). Shorter is ahead.
--
-- Drivers who have not reported yet share the same defaults (0 checkpoints, no
-- distance), so the pre-existing laps-led / grid-position tie-breaks still
-- decide those cases exactly as they did before.
local function raceOrderLess(a, b)
  local ra, rb = classRank(a), classRank(b)
  if ra ~= rb then return ra < rb end
  -- Finishers (and drivers excluded after finishing) are ordered by the flag.
  if (ra == 0 or ra == 2) and a.finishTime and b.finishTime and a.finishTime ~= b.finishTime then
    return a.finishTime < b.finishTime
  end
  -- 1. Laps completed.
  if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
  -- 2. Checkpoints cleared on the current lap.
  local ca, cb = a.cpCleared or 0, b.cpCleared or 0
  if ca ~= cb then return ca > cb end
  -- 3. Distance to the next checkpoint (a driver who has not reported one is
  --    treated as infinitely far away, i.e. behind anyone who has).
  local da, db = a.distNext or math.huge, b.distNext or math.huge
  if da ~= db then return da < db end
  -- Stable fallbacks: laps led, then the starting grid.
  if a.lapsLed ~= b.lapsLed then return a.lapsLed > b.lapsLed end
  return (a.gridPos or math.huge) < (b.gridPos or math.huge)
end

-- Stamp each driver with their place in the order the list is already in.
-- Called on every broadcast, so `position` is always in sync with the array
-- the clients receive.
local function assignPositions(list)
  for i, rec in ipairs(list) do rec.position = i end
  return list
end

local function buildDrivers()
  local list = {}
  for _, rec in pairs(players) do
    list[#list + 1] = rec
  end
  if race.phase == 'qualifying' or race.phase == 'waiting' then
    -- Provisional grid order: fastest quali Best Lap first, no-time last.
    table.sort(list, function (a, b)
      local ta, tb = a.qualiBest, b.qualiBest
      if ta and tb then
        if ta ~= tb then return ta < tb end
      elseif ta ~= tb then
        return ta ~= nil  -- drivers with a time ahead of drivers without
      end
      return a.id < b.id
    end)
  else
    -- Race order: finished first (by finish time), then the live running order
    -- (laps > checkpoints > distance to the next checkpoint), then excluded
    -- (joker ruling) drivers, DNFs last.
    table.sort(list, raceOrderLess)
  end
  -- The array clients receive is already sorted leader-first, and every driver
  -- carries the matching position integer.
  return assignPositions(list)
end

-- Forward declaration: the garage store lives further down the file (its own
-- module), but the state broadcast has to advertise the approved car list.
local garageSnapshot

-- Stamped into every state broadcast. The client bridge drops broadcasts
-- without the current stamp: they come from an OUTDATED copy of this plugin
-- still installed alongside (two copies alternating broadcasts made every UI
-- element flicker between two states on each tick).
local RM_PROTOCOL = 2

-- Build stamp, reported to the UI so the three halves of this mod can be
-- compared at a glance. They are deployed separately -- the server plugin is
-- copied to Resources/Server, the client zip is pushed by BeamMP, and BeamNG
-- caches UI files -- so any one of them can be older than the others. That is
-- invisible today and fails in the worst possible way: Angular silently ignores
-- a call to a scope function a stale app.js does not have, so a button does
-- nothing at all, with no error in any console.
--
-- Bump this in ALL THREE files (main.lua, raceManager.lua, app.js) on EVERY
-- change that needs redeploying -- not just ones that change the client/server
-- contract. That narrower rule is what let two client-side fixes ship under one
-- stamp: the build line read as matching while a client was a fix behind, which
-- is precisely the situation this was added to make visible.
local RM_BUILD = '3.5.4-derby-draw-cache'

local function broadcastState(targetPid)
  local garageView = garageSnapshot and garageSnapshot() or {}
  -- Per-player admin status. Only meaningful on a TARGETED send -- the global
  -- broadcast is one payload for everybody, so this key is left off there and
  -- clients ignore it when absent. This is what makes RM_RequestState (which
  -- the UI app sends every time it mounts) an authoritative answer to "am I
  -- still logged in", instead of the client having to remember on its own.
  local selfAdmin = nil
  if targetPid then selfAdmin = isAuthenticated(targetPid) end
  local payload = Util.JsonEncode({
    rmProtocol   = RM_PROTOCOL,
    serverBuild  = RM_BUILD,
    phase        = race.phase,
    -- Which session the shared lifecycle is running. The phase says where in
    -- the lifecycle we are; this says what it is a lifecycle OF.
    sessionKind  = race.sessionKind,
    sessionLaps  = (race.sessionKind == 'quali')
      and (race.qualiLapLimit > 0 and race.qualiLapLimit or 0) or race.totalLaps,
    raceTime     = race.time,
    totalLaps    = race.totalLaps,
    -- League regulations (Module 1 + 2): clients enforce these locally, the
    -- server re-checks and is authoritative for the final classification.
    maxResets    = race.maxResets,
    resetMode    = race.resetMode,
    jokerEnabled = race.jokerEnabled,
    -- Race entry + starting grid.
    entryMode    = race.entryMode,
    entrants     = entrantCount(),
    gridMode     = race.gridMode,
    startSlots   = race.startSlots,
    -- Qualifying rules and clock.
    ghostQuali     = race.ghostQuali,
    qualiLapLimit  = race.qualiLapLimit,
    qualiTimeLimit = race.qualiTimeLimit,
    qualiTime      = race.qualiTime,
    qualiLeft      = race.qualiTimeLimit > 0
      and math.max(race.qualiTimeLimit - race.qualiTime, 0) or nil,
    -- The clock has expired and everyone still out is on their last lap. Carried
    -- on the state broadcast rather than a one-shot event so a client that joins
    -- (or reconnects) mid-final-lap learns about it too, instead of driving a lap
    -- it does not know is its last.
    finalLap       = race.finalLap,
    finalLapLeft   = race.finalLap and math.max(race.finalLapLeft, 0) or nil,
    -- Approved vehicle/setup list (Module 4).
    garage        = garageView.list,
    garageEnforce = garageView.enforce,
    -- True when at least one session is currently logged in as an admin. Lets
    -- non-admin clients auto-spectate (skip the login prompt) when someone is
    -- already running the session, while still exposing a way back to login.
    adminPresent = next(authenticatedPlayers) ~= nil,
    -- "Are YOU an admin" (targeted sends only; nil drops out of the JSON).
    youAreAdmin  = selfAdmin,
    drivers      = buildDrivers(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

-- Forced spectator mode (Module 1). A driver who is out of the session (reset
-- allowance spent, or eliminated in a derby) gets their vehicle removed and
-- their camera pinned to freecam until the session ends. `source` scopes the
-- lock so the racing state machine and the isolated derby module can never
-- release each other's spectators.
local function forceSpectate(pid, reason, source)
  MP.TriggerClientEvent(pid, 'RM_ForceSpectate', Util.JsonEncode({
    reason = reason or 'You are out of this session',
    source = source or 'race',
  }))
end

local function releaseSpectators(source, targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_ReleaseSpectate',
    Util.JsonEncode({ source = source or 'race' }))
end

-- Starting grid. The server decides WHICH slot a driver gets; only the client
-- can put the car there (no physics access here), so the slot number is all
-- that goes over the wire. A nil slot clears any placement.
--
-- `order` and `count` describe this driver's place in the field. They exist for
-- one reason: a whole grid teleporting into position on the same tick is how a
-- placement gets refused for an occupied location, or lands two cars inside each
-- other and throws them apart. The client uses them to stagger its own
-- placement and to ghost itself while the field is landing.
local function assignGridSlot(pid, slot, order, count)
  MP.TriggerClientEvent(pid, 'RM_GridAssign', Util.JsonEncode({
    slot = slot, order = order, count = count,
  }))
end

local function broadcastCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_Countdown', Util.JsonEncode({ count = count }))
end

-- ---------------------------------------------------------------------------
-- Admin authentication events
-- ---------------------------------------------------------------------------
-- A client submits the master password. On a match the session is marked as an
-- admin and told to reveal its editor/admin controls; on a miss any prior
-- admin flag for that session is cleared and a failure is reported.
function RM_onLogin(pid, rawData)
  local pass = decodeString(rawData, 'password')
  if pass ~= nil and pass == adminPassword then
    authenticatedPlayers[pid] = true
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = true }))
    -- Tell every client an admin is now present (updates their adminPresent).
    broadcastState()
    print('[RaceManager] Admin login OK: ' .. (MP.GetPlayerName(pid) or pid))
  else
    authenticatedPlayers[pid] = nil
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = false }))
    print('[RaceManager] Admin login FAILED: ' .. (MP.GetPlayerName(pid) or pid))
  end
end

-- An admin voluntarily drops their admin rights (the UI "Log out"/back-to-login
-- action). Broadcasts state so every client's adminPresent flag stays accurate.
function RM_onLogout(pid)
  if authenticatedPlayers[pid] == nil then return end
  authenticatedPlayers[pid] = nil
  broadcastState()
  print('[RaceManager] Admin logged out: ' .. (MP.GetPlayerName(pid) or pid))
end

-- An already-authenticated admin rotates the master password. The new password
-- takes effect immediately for future logins; sessions already logged in stay
-- logged in. The password itself is never broadcast -- only a notice that it
-- changed (and by whom) goes to the server state so every open UI can reflect it.
function RM_onChangePassword(pid, rawData)
  if not requireAuth(pid) then return end
  local newPass = decodeString(rawData, 'password')
  if not newPass or newPass == '' then return end
  adminPassword = newPass
  MP.TriggerClientEvent(-1, 'RM_PasswordChanged', Util.JsonEncode({
    changedBy = MP.GetPlayerName(pid) or ('Player ' .. pid),
  }))
  print('[RaceManager] Admin password changed by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Results logging
-- ---------------------------------------------------------------------------
-- Written automatically when a race session ends; one .txt per session so
-- league standings / broadcast scripts can pick them up.
local RESULTS_DIR = 'Resources/Server/RaceManager/results'

local function fmtLap(t)
  if not t then return 'no time' end
  local m = math.floor(t / 60)
  return string.format('%d:%06.3f', m, t - m * 60)
end

-- BeamMP ships an FS API; the io/os fallback keeps headless tests runnable.
local function ensureResultsDir()
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(RESULTS_DIR)
  else
    os.execute('mkdir -p "' .. RESULTS_DIR .. '"')
  end
end

-- Timestamped result path that never overwrites: sessions ending within the
-- same second get a _2, _3, ... suffix instead of clobbering the previous file.
local function uniqueResultsPath(prefix)
  local base = RESULTS_DIR .. '/' .. os.date(prefix .. '_%Y-%m-%d_%H-%M-%S')
  local path = base .. '.txt'
  local n = 1
  while true do
    local f = io.open(path, 'r')
    if not f then return path end
    f:close()
    n = n + 1
    path = base .. '_' .. n .. '.txt'
  end
end

local function listResultFiles()
  local names = {}
  if FS and FS.ListFiles then
    for _, entry in pairs(FS.ListFiles(RESULTS_DIR) or {}) do
      local name = tostring(entry):match('[^/\\]+$')
      if name and name:match('%.txt$') then names[#names + 1] = name end
    end
  else
    local p = io.popen('ls -1 "' .. RESULTS_DIR .. '" 2>/dev/null')
    if p then
      for name in p:lines() do
        if name:match('%.txt$') then names[#names + 1] = name end
      end
      p:close()
    end
  end
  return names
end

local function clearResultsCache()
  local removed = 0
  for _, name in ipairs(listResultFiles()) do
    local path = RESULTS_DIR .. '/' .. name
    local ok
    if FS and FS.Remove then
      ok = FS.Remove(path) ~= false
    else
      ok = os.remove(path) ~= nil
    end
    if ok then removed = removed + 1 end
  end
  return removed
end

-- Qualifying classification: the locked grid if one exists, otherwise best
-- quali lap. This is deliberately independent of the race outcome so the
-- pole sitter and the race winner stay distinct in the output.
-- Results are a SNAPSHOT, not a live view: the file records the name the driver
-- raced under. There is no player id in the exported format to resolve against
-- later, so a rename can never rewrite history -- but it also means the real
-- guest name has to be carried alongside an alias, or the file loses the only
-- thread back to the session that set the lap times.
local function aliasNote(rec)
  if not aliasOf(rec) then return '' end
  return '  [' .. rec.name .. ']'
end

local function qualiClassification()
  local list = {}
  for _, rec in pairs(players) do list[#list + 1] = rec end
  table.sort(list, function (a, b)
    if a.gridPos and b.gridPos then return a.gridPos < b.gridPos end
    if (a.gridPos ~= nil) ~= (b.gridPos ~= nil) then return a.gridPos ~= nil end
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then return ta < tb end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end)
  return list
end

-- Race classification: finishers by finish time, then unclassified by laps
-- completed, excluded drivers, DNFs last (same ordering the live table uses).
local function raceClassification()
  local list = {}
  for _, rec in pairs(players) do list[#list + 1] = rec end
  table.sort(list, raceOrderLess)
  return list
end

local function buildResultsText()
  local quali = qualiClassification()
  local final = raceClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  add('==================================================')
  add(' RACE MANAGER - SESSION RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Race distance: %d lap%s | Drivers: %d',
    race.totalLaps, race.totalLaps == 1 and '' or 's', #final))
  add(string.format(' Regulations: resets %s | joker lap %s',
    race.maxResets < 0 and 'unlimited'
      or (race.maxResets == 0 and 'not allowed' or tostring(race.maxResets) .. ' per driver'),
    race.jokerEnabled and 'required exactly once' or 'disabled'))
  add('==================================================')
  add('')
  add('--- QUALIFYING RESULTS ---')
  add(string.format(' Format: %s%s%s',
    race.ghostQuali and 'ghost mode' or 'standard',
    race.qualiLapLimit > 0 and (', ' .. race.qualiLapLimit .. ' lap limit') or '',
    race.qualiTimeLimit > 0 and (', ' .. race.qualiTimeLimit .. 's limit') or ''))
  add(string.format('%-5s %-22s %-10s %s', 'Pos', 'Driver', 'Best Lap', 'Laps'))
  for i, rec in ipairs(quali) do
    local tag = (i == 1 and rec.qualiBest) and '  << POLE POSITION' or ''
    add(string.format('P%-4d %-22s %-10s %-5d%s%s',
      i, displayName(rec), fmtLap(rec.qualiBest), rec.qualiLaps or 0, aliasNote(rec), tag))
  end
  if #quali == 0 then add('(no drivers)') end
  add('')
  add('--- RACE RESULTS ---')
  -- Optional regulation columns: only present when that regulation is armed,
  -- so a plain race exports exactly the same table it always did.
  local jokerCol  = race.jokerEnabled and string.format(' %-7s', 'Joker') or ''
  local resetCol  = race.maxResets >= 0 and string.format(' %-6s', 'Resets') or ''
  add(string.format('%-5s %-22s %-10s %-9s %s%s%s',
    'Pos', 'Driver', 'Best Lap', 'Laps Led', 'Finish', jokerCol, resetCol))
  for i, rec in ipairs(final) do
    local excluded   = rec.status == 'dsq'
    local classified = rec.finishTime ~= nil and not excluded
    local pos, finish
    if excluded then
      pos, finish = 'DSQ', rec.outReason or 'Disqualified'
    elseif classified then
      pos, finish = 'P' .. i, fmtLap(rec.finishTime)
    else
      pos, finish = 'DNF', rec.outReason or 'DNF'
    end
    local tag = (i == 1 and classified) and '  << RACE WINNER' or ''
    local jokerVal = race.jokerEnabled
      and string.format(' %-7s', (rec.jokerTaken or 0) == 0 and 'missed'
        or ('lap ' .. tostring(rec.jokerLap or '?'))) or ''
    -- Blocked attempts are appended so a driver who kept pressing R after
    -- running out shows up as e.g. "3/3+2" rather than looking identical to
    -- someone who simply used their allowance.
    local resetVal = race.maxResets >= 0
      and string.format(' %-6s', string.format('%d/%d%s', rec.resets or 0, race.maxResets,
        (rec.resetsBlocked or 0) > 0 and ('+' .. rec.resetsBlocked) or '')) or ''
    add(string.format('%-5s %-22s %-10s %-9d %-10s%s%s%s%s',
      pos, displayName(rec), fmtLap(rec.raceBest), rec.lapsLed or 0, finish,
      jokerVal, resetVal, aliasNote(rec), tag))
  end
  if #final == 0 then add('(no drivers)') end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeResults()
  ensureResultsDir()
  local path = uniqueResultsPath('results')
  local text = buildResultsText()
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(text)
  f:close()
  return true, path
end

-- ---------------------------------------------------------------------------
-- Joker lap ruling (Module 2)
-- ---------------------------------------------------------------------------
-- Clients police the joker route live (one run per race, never on lap 1) and
-- report each valid completion with RM_JokerLap. The server is authoritative
-- at the flag: every driver who completed the race must have taken the joker
-- route exactly once, or their final result becomes a disqualification that is
-- written straight into the results .txt.
local function applyJokerRuling()
  if not race.jokerEnabled then return 0 end
  local excluded = 0
  for _, rec in pairs(players) do
    if rec.status == 'finished' and (rec.jokerTaken or 0) ~= 1 then
      rec.status = 'dsq'
      rec.outReason = (rec.jokerTaken or 0) == 0
        and 'Disqualified - Missed Joker'
        or  'Disqualified - Extra Joker'
      excluded = excluded + 1
      print(string.format('[RaceManager] Joker ruling: %s %s (took it %d time(s))',
        rec.name, rec.outReason, rec.jokerTaken or 0))
    end
  end
  return excluded
end

-- ---------------------------------------------------------------------------
-- Session lifecycle (shared by racing and qualifying)
-- ---------------------------------------------------------------------------
-- One lifecycle, two sets of rules. Everything below asks the session what it
-- is running rather than branching on the phase name, so a fix to the grid, the
-- hold, the finish or the respawn lands on both sessions at once.

local function isQualiSession()
  return race.sessionKind == 'quali'
end

-- The lap count the CURRENT session runs to, or nil when it has no lap target
-- (an unlimited qualifying session, closed by its clock or by the admin).
local function sessionLapTarget()
  if isQualiSession() then
    return race.qualiLapLimit > 0 and race.qualiLapLimit or nil
  end
  return race.totalLaps
end

-- The status a driver carries while they are circulating. Presentation only --
-- every check in this file goes through onTrack() -- but it keeps the timing
-- screen reading "Qualifying" during qualifying and "Racing" during a race.
local function runningStatus()
  return isQualiSession() and 'qualifying' or 'racing'
end

local function onTrack(rec)
  return rec ~= nil and (rec.status == 'racing' or rec.status == 'qualifying')
end

-- The lights have gone out and cars are circulating: laps count, telemetry
-- counts, the clock runs.
local function sessionRunning()
  return race.phase == 'racing' or race.phase == 'qualifying'
end

-- The session is under way: the lights have gone out (or are about to) and
-- nothing about the rules may move under the drivers. Qualifying is included
-- now that it is a real session rather than an open pit lane.
local function sessionUnderWay()
  return race.phase == 'countdown' or race.phase == 'racing' or race.phase == 'qualifying'
end

-- How many drivers are still circulating. Every "is this session over?" test in
-- the file asks this, so there is one answer to it.
local function driversOnTrack()
  local n = 0
  for _, rec in pairs(players) do
    if onTrack(rec) then n = n + 1 end
  end
  return n
end

-- Take one driver off the track: they are done, their car is removed, and they
-- watch until the session ends. THE single removal path -- the lap target, the
-- expired-clock final lap and the grace timeout all come through here, so a
-- driver's session ends the same way whichever of the three finished it.
local function retireDriver(rec, reason)
  if not onTrack(rec) then return false end
  rec.status = 'finished'
  rec.finishTime = race.time
  forceSpectate(rec.id, reason, 'race')
  return true
end

-- Forward declaration: the grid is formed by one function used by BOTH entry
-- points (Generate Grid and Start Qualifying), and it needs the ordering rules
-- that are defined further down the file.
local formGrid

-- Give a field of drivers their cars back.
--
-- THE mass-respawn mechanism, and the only one. It takes the field as two
-- ready-made arrays rather than going and finding it, for two reasons:
--
--   * both lists must be SNAPSHOTS. The release is what makes a client delete
--     its freecam and spawn a vehicle, and building a list while that is under
--     way is how a mass respawn ends up reaching only the last name in it.
--   * the demo derby keeps its own participant table and never reads racing
--     state. Handing the field in is what lets it share this without either
--     module learning about the other's players.
--
-- `participants` are the drivers whose cars were removed, in the order they
-- should come back; each is told its place. Five cars materialising in the same
-- instant is how a respawn gets refused for an occupied location, or lands two
-- cars inside each other and blows them apart; the clients use the order to
-- stagger their spawns and to ghost themselves while it happens.
--
-- `bystanders` (optional) still get the lock lifted -- they simply have no place
-- in the order, because they have no car to put back.
local function respawnField(source, participants, bystanders)
  source = source or 'race'
  for i, rec in ipairs(participants) do
    MP.TriggerClientEvent(rec.id, 'RM_ReleaseSpectate', Util.JsonEncode({
      source = source, order = i, count = #participants,
    }))
  end
  for _, rec in ipairs(bystanders or {}) do
    MP.TriggerClientEvent(rec.id, 'RM_ReleaseSpectate', Util.JsonEncode({ source = source }))
  end
  print(string.format('[RaceManager] Respawning %d %s participant(s) (%d bystander(s))',
    #participants, source, bystanders and #bystanders or 0))
end

-- The racing field, in grid order, handed to respawnField above.
local function respawnAll(source)
  local field = {}
  for _, rec in pairs(players) do
    field[#field + 1] = rec
  end
  table.sort(field, function (a, b)
    return (a.gridPos or math.huge) < (b.gridPos or math.huge)
      or ((a.gridPos or math.huge) == (b.gridPos or math.huge) and a.id < b.id)
  end)

  local participants, bystanders = {}, {}
  for _, rec in ipairs(field) do
    if rec.gridPos or isEntrant(rec) then
      participants[#participants + 1] = rec
    else
      bystanders[#bystanders + 1] = rec
    end
  end
  respawnField(source or 'race', participants, bystanders)
end

-- Single exit point for every way a session ends (everyone finished, the clock
-- ran out, the admin ended it, the last driver disconnected). Both kinds go
-- through here, so both get the same close-down: stop the clock, put every
-- removed car back, then apply whichever rules belong to that session.
local function finishSession(reason)
  MP.CancelEventTimer('RM_CountdownTick')
  race.finalLap     = false
  race.finalLapLeft = 0
  if isQualiSession() then
    -- Qualifying drops back to waiting rather than 'finished': the next thing
    -- an admin does is Generate Grid, and the times just set are what orders it.
    race.phase = 'waiting'
    for _, rec in pairs(players) do
      if onTrack(rec) then rec.status = 'waiting' end
    end
    respawnAll('race')
    broadcastState()
    MP.SendChatMessage(-1, '[RaceManager] Qualifying is over — ' .. reason .. '.')
    print('[RaceManager] Qualifying closed: ' .. reason)
    return
  end

  local excluded = applyJokerRuling()
  race.phase = 'finished'
  -- The session is over: every car taken off the track comes back.
  respawnAll('race')
  broadcastState()
  if excluded > 0 then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Joker lap ruling: %d driver%s disqualified for not taking the Joker Route exactly once.',
      excluded, excluded == 1 and '' or 's'))
  end
  print('[RaceManager] Race over: ' .. reason)
  local ok, wrote, pathOrErr = pcall(writeResults)
  if ok and wrote then
    MP.SendChatMessage(-1, '[RaceManager] Session complete! Results saved on the server: ' .. pathOrErr)
    print('[RaceManager] Results written to ' .. pathOrErr)
  else
    print('[RaceManager] Failed to write results: ' .. tostring(ok and pathOrErr or wrote))
  end
end

-- ---------------------------------------------------------------------------
-- Session state machine (UI commands relayed by the client bridge)
-- ---------------------------------------------------------------------------

-- Start Qualifying: wipe the previous session's times and form the qualifying
-- grid. Allowed any time a session is not already under way.
--
-- This is the SAME grid path Generate Grid takes -- form up, stand every
-- entrant on a slot, hold them there for the countdown. Qualifying used to skip
-- all of it and simply flip the phase, which left every driver starting from
-- wherever they happened to be parked: the first crossing of the line was an
-- out-lap nobody asked for, a driver sitting mid-route had to complete a lap
-- before their first one even began to count, and a "3 lap" session took five
-- or six laps to get through. Starting from the grid is what makes three laps
-- mean three laps.
--
-- Display names and entry decisions are NOT wiped: they live in the identity
-- registry and are restored by ensurePlayer inside formGrid.
function RM_onStartQualifying(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  MP.CancelEventTimer('RM_CountdownTick')
  players = {}
  lapFirsts = {}
  race.time = 0.0
  race.qualiTime = 0.0
  if not formGrid('quali', MP.GetPlayerName(pid) or pid) then return end
  print(string.format('[RaceManager] Qualifying grid formed by %s (%d entrant(s), entry: %s%s%s)',
    MP.GetPlayerName(pid) or pid, entrantCount(), race.entryMode,
    race.qualiLapLimit > 0 and (', ' .. race.qualiLapLimit .. ' lap limit') or '',
    race.qualiTimeLimit > 0 and (', ' .. race.qualiTimeLimit .. 's limit') or ''))
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] Qualifying grid formed (%s). Start Countdown to begin the session.',
    race.qualiLapLimit > 0 and (race.qualiLapLimit .. ' lap' .. (race.qualiLapLimit == 1 and '' or 's'))
      or 'unlimited laps'))
end

-- ---------------------------------------------------------------------------
-- Race entry (opt-in)
-- ---------------------------------------------------------------------------
-- Any player can add or remove themselves; no admin rights involved, because
-- this is a statement about their own participation. Joining mid-qualifying is
-- allowed (you just have less time); joining once the grid is locked is not,
-- because the field is already set.
function RM_onJoinRace(pid, rawData)
  local rec = ensurePlayer(pid)
  local join = true
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' and data.join ~= nil then
      join = data.join == true or data.join == 1
    end
  end
  if join and sessionUnderWay() then
    print('[RaceManager] Join refused for ' .. rec.name .. ': the session is under way')
    return
  end
  if rec.joined == join then return end
  rec.joined = join
  -- Entering is a decision about the EVENT, not about one session, so it goes
  -- in the registry and survives every session wipe below.
  rememberIdentity(rec)
  if join then
    if race.phase == 'qualifying' then rec.status = 'qualifying' end
  else
    -- Withdrawing gives up any grid slot and any placement on track.
    rec.status  = 'waiting'
    rec.gridPos = nil
    rec.customGrid = nil
    if race.phase == 'grid' then assignGridSlot(pid, nil) end
  end
  broadcastState()
  -- An opt-in derby draws its field from this same list, so refresh that panel
  -- too or its entrant count sits stale until something else moves.
  if derbyEntryListChanged then derbyEntryListChanged() end
  MP.SendChatMessage(-1, string.format('[RaceManager] %s %s the race (%d entrant%s).',
    displayName(rec), join and 'JOINED' or 'left', entrantCount(),
    entrantCount() == 1 and '' or 's'))
  print('[RaceManager] ' .. rec.name .. (join and ' joined' or ' left') .. ' the race')
end

-- Admin switches between opt-in entry and "everyone on the server races".
function RM_onSetEntryMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'all' and mode ~= 'join' then return end
  race.entryMode = mode
  broadcastState()
  if derbyEntryListChanged then derbyEntryListChanged() end
  print('[RaceManager] Race entry mode set to "' .. mode .. '" by '
    .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Qualifying session rules
-- ---------------------------------------------------------------------------
-- Ghost mode is enforced client-side (only the client owns collisions); the
-- server just holds the switch and ships it with every broadcast.
function RM_onSetGhostQuali(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  race.ghostQuali = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Ghost qualifying ' .. (race.ghostQuali and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Session length: a per-driver lap allowance, a wall-clock limit, or neither.
-- 0 means unlimited for both. Locked while qualifying is actually running so a
-- driver can't have the rug pulled mid-lap.
function RM_onSetQualiLimits(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local laps = tonumber(data.laps)
  local secs = tonumber(data.seconds)
  if laps then
    laps = math.floor(laps)
    if laps < 0 then laps = 0 elseif laps > MAX_QUALI_LAPS then laps = MAX_QUALI_LAPS end
    race.qualiLapLimit = laps
  end
  if secs then
    secs = math.floor(secs)
    if secs < 0 then secs = 0 elseif secs > MAX_QUALI_TIME then secs = MAX_QUALI_TIME end
    race.qualiTimeLimit = secs
  end
  broadcastState()
  print(string.format('[RaceManager] Qualifying limits set by %s: %s laps, %s',
    MP.GetPlayerName(pid) or pid,
    race.qualiLapLimit == 0 and 'unlimited' or tostring(race.qualiLapLimit),
    race.qualiTimeLimit == 0 and 'no time limit' or (race.qualiTimeLimit .. 's')))
end

-- Close qualifying. Everyone keeps their Best Lap and every car comes back;
-- both of those are finishSession's job now, shared with the race, so this is
-- only the guard that says a qualifying session is what is running.
local function endQualifying(reason)
  if race.phase ~= 'qualifying' or not isQualiSession() then return end
  finishSession(reason)
end

-- The qualifying clock has run out.
--
-- This does NOT end the session, and that is the whole point. It arms the final
-- lap: everybody stays controllable and out on track, and the next start/finish
-- line each of them crosses ends their session instead of starting another lap.
-- The session closes when the last of them has taken the flag -- through exactly
-- the same removal and respawn-all a lap-limited session uses.
--
-- Ending it outright, which is what used to happen here, locked the leaderboard
-- and left every car loose on an over circuit: nothing was removed, so the
-- respawn had nothing to put back and no driver was ever told the session was
-- done.
local function beginFinalLap()
  if race.finalLap then return end
  -- Nobody left out there (everyone already used a lap allowance, or the field
  -- emptied): there is no final lap to run, so close cleanly rather than arming
  -- a state that nothing can ever leave.
  if driversOnTrack() == 0 then
    endQualifying('the time limit expired')
    return
  end
  race.finalLap     = true
  race.finalLapLeft = FINAL_LAP_GRACE
  broadcastState()
  MP.SendChatMessage(-1, '[RaceManager] TIME EXPIRED — the lap you are on is your '
    .. 'FINAL LAP. Your session ends as you cross the line.')
  print(string.format('[RaceManager] Qualifying time expired: final lap armed for %d driver(s)',
    driversOnTrack()))
end

-- Deterministic shuffle for the random grid draw. os.time seeding is fine
-- here: two grids drawn in the same second is not a fairness problem, and
-- nothing else on the server depends on the RNG stream.
local randomSeeded = false
local function shuffle(list)
  if not randomSeeded then
    math.randomseed(os.time() + os.clock() * 1000)
    randomSeeded = true
  end
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

-- Fill the grid in the order race.gridMode asks for:
--   quali  -- fastest qualifying Best Lap first, no-time last (join order breaks ties)
--   random -- a random draw, for a race with no qualifying behind it
--   custom -- slots the admin pinned by hand come first, in slot order; anyone
--             unpinned falls in behind them, still by quali time
local function orderForGrid(ordered)
  if race.gridMode == 'random' then
    return shuffle(ordered)
  end
  local function byQuali(a, b)
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then return ta < tb end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end
  if race.gridMode == 'custom' then
    table.sort(ordered, function (a, b)
      local ca, cb = a.customGrid, b.customGrid
      if ca and cb then
        if ca ~= cb then return ca < cb end
      elseif ca ~= cb then
        return ca ~= nil        -- pinned drivers ahead of unpinned ones
      end
      return byQuali(a, b)
    end)
    return ordered
  end
  table.sort(ordered, byQuali)
  return ordered
end

-- Form the grid for a session. THE one implementation, filling the forward
-- declaration made up beside finishSession.
--
-- Both entry points come through here -- Generate Grid for a race, Start
-- Qualifying for a qualifying session -- because there used to be two routes to
-- the grid and only one of them worked. With every driver opted in individually
-- the field came out empty and no car was ever teleported, while "Everyone
-- races" put the same five drivers on the grid without complaint; the
-- difference was never in the placement code, it was in what survived the
-- online purge below.
--
-- Returns true when a grid was actually formed.
formGrid = function (kind, byName)
  race.sessionKind = (kind == 'quali') and 'quali' or 'race'
  race.time = 0.0
  race.finalLap     = false
  race.finalLapLeft = 0
  lapFirsts = {}

  -- Purge ghost records first: drivers kept after disconnecting (DNF/finished,
  -- so the previous results file could list them) must not be re-gridded — a
  -- ghost would be flipped to running at GO, never report a lap, and block the
  -- "all drivers finished" auto-finish forever.
  --
  -- onlinePlayers() is what makes this safe. The purge compares the key a record
  -- is stored under against the keys the server reports as connected, and if
  -- those two do not compare equal EVERY record is purged -- taking every
  -- `joined` flag with it, one line before the entry list is read. That reads
  -- as "nobody has joined" no matter how many drivers pressed the button, and
  -- it is invisible in "everyone races" mode because isEntrant never looks at
  -- the flag there.
  local online = onlinePlayers()
  for id in pairs(players) do
    if online[id] == nil then players[id] = nil end
  end
  -- Make sure every connected player has a record so the entry list is complete.
  -- ensurePlayer restores the display name and the entry decision from the
  -- identity registry, so a driver who opted in before the last session wipe is
  -- still an entrant here.
  for id in pairs(online) do ensurePlayer(id) end

  local ordered, skipped = {}, {}
  for _, rec in pairs(players) do
    if isEntrant(rec) then
      ordered[#ordered + 1] = rec
    else
      -- Not entered: explicitly off the grid, and holding no stale slot.
      skipped[#skipped + 1] = rec.name
      rec.gridPos = nil
      rec.status  = 'waiting'
      assignGridSlot(rec.id, nil)
    end
  end

  if #ordered == 0 then
    -- Never a bare "nobody joined". An empty field with players connected is
    -- the exact shape the opt-in bug took, and the one thing that would have
    -- identified it is a line saying who was considered and why they were not
    -- entered.
    local connected = 0
    for _ in pairs(online) do connected = connected + 1 end
    print(string.format(
      '[RaceManager] Grid not formed: no entrants (entry mode "%s", %d connected, %d record(s): %s)',
      race.entryMode, connected, #skipped,
      #skipped > 0 and table.concat(skipped, ', ') or 'none'))
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Nobody is entered for this session (%d connected, entry mode "%s") — '
        .. 'press Join Race in the Race Manager app, or switch entry to Everyone.',
      connected, race.entryMode))
    return false
  end

  orderForGrid(ordered)
  -- Locks come off BEFORE the slots go out. A driver still serving a spectator
  -- penalty from the last session has no car at all, and a start position sent
  -- to a client with nothing to place is a slot silently dropped on the floor.
  -- The client coalesces the two: it puts its car back and stands it on the
  -- slot as one ghosted, staggered operation.
  releaseSpectators('race')
  for gridPos, rec in ipairs(ordered) do
    rec.gridPos    = gridPos
    rec.status     = 'gridded'
    rec.raceBest   = nil
    rec.currentLap = 0
    rec.lapsLed    = 0
    rec.finishTime = nil
    -- New session: reset allowance and joker credit start over for everyone.
    rec.resets     = 0
    rec.resetsBlocked = 0
    rec.jokerTaken = 0
    rec.jokerLap   = nil
    rec.outReason  = nil
    -- A qualifying grid also clears the times it is about to replace.
    if isQualiSession() then
      rec.qualiBest = nil
      rec.qualiLaps = 0
    end
    clearProgress(rec)
    -- Put the car on its start position and hold it there until GO. The order
    -- and the field size travel with the slot so the client can stagger its
    -- placement instead of every car being teleported in the same instant.
    assignGridSlot(rec.id, gridPos, gridPos, #ordered)
  end

  race.phase = 'grid'
  broadcastState()
  if race.startSlots > 0 and #ordered > race.startSlots then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Warning: %d drivers but only %d start positions placed — '
        .. 'the back of the grid has nowhere to line up.', #ordered, race.startSlots))
  end
  print(string.format('[RaceManager] %s grid formed by %s (%d drivers, %s order, pole: %s)',
    isQualiSession() and 'Qualifying' or 'Race', tostring(byName), #ordered, race.gridMode,
    ordered[1] and ordered[1].name or 'n/a'))
  return true
end

-- Generate Grid: form the race grid. Drivers who join afterwards go to the back
-- on the next Generate Grid. Also usable from waiting/finished: with no quali
-- times everyone ties and the grid falls back to join order.
function RM_onGenerateGrid(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  formGrid('race', MP.GetPlayerName(pid) or pid)
end

-- How the grid gets filled. Locked once the countdown/race starts.
function RM_onSetGridMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'quali' and mode ~= 'random' and mode ~= 'custom' then return end
  race.gridMode = mode
  broadcastState()
  print('[RaceManager] Grid mode set to "' .. mode .. '" by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Custom grid: pin one driver to one slot. Whoever already held that slot is
-- unpinned, so two drivers can never be pinned to the same place. Takes effect
-- on the next Generate Grid; when the grid is already formed it re-forms the
-- order immediately so the admin sees the result.
function RM_onSetDriverGrid(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local target = tonumber(data.pid)
  local slot   = tonumber(data.slot)
  if not target or not slot then return end
  target, slot = math.floor(target), math.floor(slot)
  local rec = players[target]
  if not rec or slot < 1 then return end
  for _, other in pairs(players) do
    if other.customGrid == slot and other.id ~= target then other.customGrid = nil end
  end
  rec.customGrid = slot
  race.gridMode = 'custom'
  broadcastState()
  print(string.format('[RaceManager] %s pinned to grid slot %d by %s',
    rec.name, slot, MP.GetPlayerName(pid) or pid))
end

-- A client reported how many start positions the loaded track layout has, so
-- the server can warn when the field is bigger than the grid.
function RM_onStartPositionCount(pid, rawData)
  local n = decodeNumber(rawData, 'count')
  if not n then return end
  n = math.floor(n)
  if n < 0 then n = 0 end
  if n == race.startSlots then return end
  race.startSlots = n
  broadcastState()
end

-- Admin sets or clears a driver's display alias. Admin-only on purpose: with
-- guest-only identities there is nothing to enforce a ban against, so a
-- self-service name could be re-set the moment it was cleared.
--
-- The target is addressed by BeamMP player id -- the same key race logic uses --
-- and only rec.alias is written. No timing, checkpoint or scoring field is
-- touched, and the alias is never read back as a key.
--
-- EVERY exit path reports back. An admin pressing Set and getting nothing at
-- all -- no name, no reason -- cannot tell a rejected name from a plugin that
-- never received the event, which is exactly the dead end this handler used to
-- leave them in.
local function aliasResult(pid, ok, msg)
  MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
    success = ok and true or false,
    message = msg,
  }))
  print('[RaceManager] Alias: ' .. msg)
end

function RM_onSetAlias(pid, rawData)
  -- Not "return quietly": a client can believe it is an admin while the server
  -- disagrees (a restart empties authenticatedPlayers while the client bridge
  -- still holds its own flag), and silence there looks exactly like a broken
  -- button. Say so, and the client drops its stale admin state.
  if not isAuthenticated(pid) then
    print('[RaceManager] Ignored alias command from unauthenticated player ' .. tostring(pid))
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = false }))
    aliasResult(pid, false, 'Not logged in as an admin on this server — log in again.')
    return
  end

  local target = decodeNumber(rawData, 'target')
  if not target then
    aliasResult(pid, false, 'Malformed request (no target driver).')
    return
  end
  local rec = players[math.floor(target)]
  if not rec then
    aliasResult(pid, false, 'That driver is no longer on the server.')
    return
  end

  -- A blank alias clears it and falls back to the real guest name.
  local raw = decodeString(rawData, 'alias') or ''
  if raw:gsub('%s', '') == '' then
    if rec.alias then
      local was = rec.alias
      rec.alias = nil
      rememberIdentity(rec)
      broadcastState()
      aliasResult(pid, true, 'Display name cleared for ' .. rec.name .. ' (was "' .. was .. '").')
    else
      aliasResult(pid, true, rec.name .. ' has no display name to clear.')
    end
    return
  end

  local clean, why = sanitizeAlias(raw)
  if not clean then
    aliasResult(pid, false, 'Name rejected: ' .. why .. '.')
    return
  end
  if aliasInUse(clean, rec.id) then
    aliasResult(pid, false, 'Name rejected: "' .. clean .. '" is already in use.')
    return
  end

  rec.alias = clean
  -- Into the registry, not just onto the record: the record is rebuilt by the
  -- next Start Qualifying and the name has to outlive that.
  rememberIdentity(rec)
  broadcastState()
  aliasResult(pid, true, 'Display name "' .. clean .. '" set for ' .. rec.name .. '.')
end

-- Host sets the race distance. Locked once the countdown/race is under way.

function RM_onSetTotalLaps(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local n = decodeNumber(rawData, 'laps')
  if not n then return end
  n = math.floor(n)
  if n < 1 then n = 1 elseif n > MAX_TOTAL_LAPS then n = MAX_TOTAL_LAPS end
  race.totalLaps = n
  broadcastState()
  print('[RaceManager] Total laps set to ' .. n .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Module 1: vehicle reset ruleset
-- ---------------------------------------------------------------------------
-- Host sets how many vehicle resets/repairs each driver gets per session.
--   -1 (or any negative value)  unlimited (default)
--    0                          no resets at all — the first one ends your race
--    N                          N resets, the N+1st ends your race
-- Locked once the countdown/race is under way so the rule can't change under a
-- driver who has already spent their allowance.
function RM_onSetMaxResets(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local n = decodeNumber(rawData, 'maxResets')
  if not n then return end
  n = math.floor(n)
  if n < 0 then n = UNLIMITED_RESETS elseif n > MAX_RESET_LIMIT then n = MAX_RESET_LIMIT end
  race.maxResets = n
  broadcastState()
  print('[RaceManager] Max vehicle resets set to '
    .. (n < 0 and 'unlimited' or tostring(n)) .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- What a LEGAL reset does while racing: repair in place (the default), or
-- respawn the driver at the last checkpoint they crossed. Enforced client-side
-- (only the client can move a car); the server holds the switch. Locked once
-- the countdown/race is under way, like every other regulation.
function RM_onSetResetMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'inplace' and mode ~= 'checkpoint' then return end
  race.resetMode = mode
  broadcastState()
  print('[RaceManager] Reset mode set to "' .. mode .. '" by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client consumed one of its allowed resets. The client counts locally (it is
-- the only side that sees the reset happen); the server keeps the tally that
-- the live table and the results file report.
function RM_onVehicleReset(pid)
  local rec = players[pid]
  if not rec then return end
  if not sessionUnderWay() then return end
  -- Only drivers still in the session spend allowance; a DNF'd/finished driver's
  -- resets are meaningless and must not keep growing in the results file.
  if not onTrack(rec) and rec.status ~= 'gridded' then return end
  -- The tally can never pass the limit, no matter what a client reports: an
  -- over-allowance report is recorded as a blocked attempt instead, so the
  -- counter never renders as "3/2".
  if race.maxResets >= 0 and (rec.resets or 0) >= race.maxResets then
    RM_onResetDenied(pid)
    return
  end
  rec.resets = (rec.resets or 0) + 1
  print(string.format('[RaceManager] %s used reset %d/%s',
    rec.name, rec.resets, race.maxResets < 0 and '∞' or tostring(race.maxResets)))
  broadcastState()
end

-- Client pressed a reset it was not entitled to. The client BLOCKS the reset —
-- it puts the car straight back where it was — so this is not a penalty and
-- never ends anyone's race: the attempt is only counted, so the live table and
-- the results file show who kept reaching for a reset they no longer had.
function RM_onResetDenied(pid)
  local rec = players[pid]
  if not rec then return end
  if not sessionUnderWay() then return end
  if not onTrack(rec) and rec.status ~= 'gridded' then return end
  rec.resetsBlocked = (rec.resetsBlocked or 0) + 1
  print(string.format('[RaceManager] %s: reset BLOCKED (%d blocked, allowance %s spent)',
    rec.name, rec.resetsBlocked,
    race.maxResets < 0 and 'unlimited' or tostring(race.maxResets)))
  broadcastState()
end

-- ---------------------------------------------------------------------------
-- Module 2: rallycross joker lap
-- ---------------------------------------------------------------------------
-- Host arms/disarms the joker requirement. The joker route itself is a second
-- checkpoint set built in the client editor and shipped with the track layout;
-- the server only needs to know whether the rule is in force. Locked during a
-- countdown/race so drivers can't be judged against a rule that appeared
-- mid-race.
function RM_onSetJokerEnabled(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  race.jokerEnabled = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Joker lap ' .. (race.jokerEnabled and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client completed the joker route. It already enforced "not on lap 1" and
-- "only once" locally; the server records the count (and the lap it happened
-- on) and rules on it when the race ends.
function RM_onJokerLap(pid, rawData)
  -- Race regulation only: a joker route has no meaning in qualifying.
  if race.phase ~= 'racing' or isQualiSession() then return end
  local rec = players[pidKey(pid) or -1]
  if not rec or rec.status ~= 'racing' then return end
  rec.jokerTaken = (rec.jokerTaken or 0) + 1
  local lap = decodeNumber(rawData, 'lap')
  if rec.jokerLap == nil then rec.jokerLap = lap and math.floor(lap) or rec.currentLap end
  print(string.format('[RaceManager] %s took the joker route on lap %s (total %d)',
    rec.name, tostring(rec.jokerLap), rec.jokerTaken))
  broadcastState()
end

function RM_onStartCountdown(pid)
  if not requireAuth(pid) then return end
  if race.phase ~= 'grid' then return end
  race.phase = 'countdown'
  countdownValue = COUNTDOWN_FROM
  broadcastState()
  broadcastCountdown(countdownValue)
  MP.CreateEventTimer('RM_CountdownTick', 1000)
  print('[RaceManager] Countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_CountdownTick()
  if race.phase ~= 'countdown' then
    MP.CancelEventTimer('RM_CountdownTick')
    return
  end
  countdownValue = countdownValue - 1
  if countdownValue > 0 then
    broadcastCountdown(countdownValue)
    return
  end
  -- GO! One release for both kinds of session: every held car is let go by the
  -- same broadcast, and lap 1 starts at the line for everybody.
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(0)
  race.phase = runningStatus()   -- 'qualifying' or 'racing'
  race.time = 0.0
  race.qualiTime = 0.0
  race.finalLap     = false
  race.finalLapLeft = 0
  lapFirsts = {}
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then
      rec.status     = runningStatus()
      rec.currentLap = 1
      rec.raceBest   = nil
      rec.lapsLed    = 0
      rec.finishTime = nil
      rec.resets     = 0
      rec.jokerTaken = 0
      rec.jokerLap   = nil
      rec.outReason  = nil
      if isQualiSession() then
        rec.qualiBest = nil
        rec.qualiLaps = 0
      end
      clearProgress(rec)
    end
  end
  broadcastState()
  local target = sessionLapTarget()
  print('[RaceManager] GO! (' .. (isQualiSession() and 'qualifying' or 'race') .. ', '
    .. (target and (target .. ' laps') or 'unlimited laps') .. ')'
    .. (race.jokerEnabled and not isQualiSession() and ' — JOKER LAP REQUIRED' or '')
    .. (race.maxResets >= 0 and (' — resets limited to ' .. race.maxResets) or ''))
end

-- End Session: during a race anyone still on track becomes DNF; during
-- qualifying the session closes but Best Laps are kept so the grid can
-- still be generated. Either way every car comes back (finishSession).
function RM_onEndRace(pid)
  if not requireAuth(pid) then return end
  if race.phase == 'grid' then
    -- Aborting before the lights: no result to record, just stand the field
    -- down and let the held cars go.
    broadcastCountdown(-1)
    race.phase = 'waiting'
    for _, rec in pairs(players) do
      if rec.status == 'gridded' then rec.status = 'waiting' end
    end
    respawnAll('race')
    broadcastState()
    print('[RaceManager] Grid stood down by ' .. (MP.GetPlayerName(pid) or pid))
    return
  end
  if not sessionUnderWay() then return end
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)  -- hide any countdown overlay
  if isQualiSession() then
    finishSession('ended by ' .. (MP.GetPlayerName(pid) or pid))
    return
  end
  for _, rec in pairs(players) do
    if onTrack(rec) or rec.status == 'gridded' then
      rec.status = 'dnf'
      rec.outReason = rec.outReason or 'DNF - Session ended'
    end
  end
  finishSession('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onResetLeaderboard(pid)
  if not requireAuth(pid) then return end
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  players = {}
  lapFirsts = {}
  race.phase = 'waiting'
  race.sessionKind = 'race'
  race.time = 0.0
  race.qualiTime = 0.0
  race.finalLap     = false
  race.finalLapLeft = 0
  -- The records are gone and so is the entry list, but the display names are
  -- not: they live in the identity registry and ensurePlayer hands them straight
  -- back, which is what makes a name survive from one race into the next.
  clearEntries()
  for id in pairs(onlinePlayers()) do
    ensurePlayer(id)
  end
  respawnAll('race')
  broadcastState()
  print('[RaceManager] Session reset by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Live position telemetry from clients
-- ---------------------------------------------------------------------------
-- Every racing client reports its progress a few times a second:
--   lap  -- the lap it believes it is on (sanity check only; the server's own
--           counter stays authoritative for metric 1)
--   cp   -- checkpoints cleared on the current lap (metric 2)
--   dist -- metres to the centre of the next checkpoint (metric 3)
--
-- This deliberately does NOT broadcast: with a full grid reporting at 3 Hz that
-- would be dozens of broadcasts a second. The values are just stored, and the
-- race tick loop re-sorts and pushes the running order on its own cadence.
local MAX_CHECKPOINTS = 500      -- sanity clamp on a reported checkpoint count
local MAX_REPORT_DIST = 1e6      -- metres; anything beyond this is nonsense

function RM_onProgress(pid, rawData)
  if not sessionRunning() then return end
  local rec = players[pidKey(pid) or -1]
  if not onTrack(rec) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  -- A report from a lap the server has not credited yet (or has already moved
  -- past) is dropped rather than applied: mixing a stale checkpoint count into
  -- the comparator would make positions flicker around every lap crossing.
  local lap = tonumber(data.lap)
  if lap and math.floor(lap) ~= rec.currentLap then return end

  local cp = tonumber(data.cp)
  if cp then
    cp = math.floor(cp)
    if cp < 0 then cp = 0 elseif cp > MAX_CHECKPOINTS then cp = MAX_CHECKPOINTS end
    rec.cpCleared = cp
  end

  local dist = tonumber(data.dist)
  if dist and dist >= 0 and dist <= MAX_REPORT_DIST then
    rec.distNext = dist
  end
end

-- A client crossed the start/finish line after clearing all checkpoints. ONE
-- handler for both kinds of session, which is the point: qualifying used to
-- report its laps on a channel of its own with its own counting rules, and that
-- second implementation is what drifted. The server decides Laps Led (first
-- report per lap number wins — one arrival order for everyone) and the finish
-- (the session's lap target reached).
function RM_onLap(pid, rawData)
  if not sessionRunning() then return end
  local rec = ensurePlayer(pid)
  if not rec or not onTrack(rec) then return end
  local quali = isQualiSession()
  local lapTime = decodeNumber(rawData, 'lapTime')
  if lapTime and lapTime > 0 then
    if not rec.raceBest or lapTime < rec.raceBest then rec.raceBest = lapTime end
    -- Qualifying scores on the best lap; that is the whole difference between
    -- the two sessions once the lifecycle is shared.
    if quali and (not rec.qualiBest or lapTime < rec.qualiBest) then
      rec.qualiBest = lapTime
      print(string.format('[RaceManager] %s quali best: %.3fs (lap %d)',
        rec.name, lapTime, (rec.qualiLaps or 0) + 1))
    end
  end

  local completed = rec.currentLap
  if quali then
    rec.qualiLaps = (rec.qualiLaps or 0) + 1
  elseif not lapFirsts[completed] then
    lapFirsts[completed] = pid
    rec.lapsLed = rec.lapsLed + 1
  end
  -- New lap (or the flag): the checkpoint/distance telemetry from the lap just
  -- completed must not linger and rank this driver against the next one.
  clearProgress(rec)

  -- Two ways a crossing can be a driver's last, and they are checked together so
  -- the removal below is reached by one route rather than two.
  --
  --   * the session's lap target, if it has one; or
  --   * the expired clock. Once the final lap is armed, ANY crossing that
  --     arrives is terminal.
  --
  -- That second rule is what settles the "crossed the line at almost exactly the
  -- moment the clock expired" case, and it settles it the way this file settles
  -- every other question of who was first: by arrival order at the server. A
  -- crossing the server sees before expiry starts another lap; one it sees after
  -- ends that driver's session. There is no clock skew to argue about, no
  -- client-reported timestamp to trust, and the same input always produces the
  -- same outcome.
  --
  -- Note this lap still COUNTS: the time set on it goes into Best Lap above, and
  -- can improve a driver's position. That is deliberate and it is what makes a
  -- final lap worth running -- the order is not frozen at expiry, it settles when
  -- the last driver has taken the flag.
  local target = sessionLapTarget()
  local lastLap = (target and completed >= target) or race.finalLap
  if lastLap then
    local why
    if quali and race.finalLap and not (target and completed >= target) then
      why = 'Qualifying over — you took the flag on the final lap'
    elseif quali then
      why = 'Qualifying session complete — spectating until the flag'
    else
      why = 'You finished the race — spectating until the flag'
    end
    -- A car that is done is taken off the track: it has nothing left to gain and
    -- a parked (or cruising) driver is an obstacle for everyone still running.
    -- Every one of them comes back at the flag (respawnAll in finishSession), so
    -- nobody is left stranded.
    retireDriver(rec, why)
    print(string.format('[RaceManager] %s completed %d lap(s) at %.3fs (led %d)%s',
      rec.name, completed, race.time, rec.lapsLed, race.finalLap and ' [final lap]' or ''))
    if quali and target and completed >= target then
      MP.SendChatMessage(-1, string.format('[RaceManager] %s has used all %d qualifying lap%s.',
        displayName(rec), target, target == 1 and '' or 's'))
    elseif race.finalLap then
      MP.SendChatMessage(-1, string.format('[RaceManager] %s has taken the flag (%d still out).',
        displayName(rec), driversOnTrack()))
    end
    -- Everyone done (finished or dnf)? Close the session.
    if driversOnTrack() > 0 then
      broadcastState()
      return
    end
    finishSession(race.finalLap and 'every driver took the flag'
      or (quali and 'every driver used their lap allowance' or 'all drivers finished'))
    return
  end
  rec.currentLap = completed + 1
  broadcastState()
end

-- Clear Results Cache: delete every saved .txt in the results folder.
function RM_onClearResults(pid)
  if not requireAuth(pid) then return end
  local ok, removed = pcall(clearResultsCache)
  if not ok then
    print('[RaceManager] Failed to clear results cache: ' .. tostring(removed))
    return
  end
  local msg = string.format('[RaceManager] Results cache cleared by %s (%d file%s removed from %s)',
    MP.GetPlayerName(pid) or pid, removed, removed == 1 and '' or 's', RESULTS_DIR)
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Client asks for current state (UI app just opened).
function RM_onRequestState(pid)
  broadcastState(pid)
end

-- ---------------------------------------------------------------------------
-- Track layouts: persistent, per-map checkpoint configurations
-- ---------------------------------------------------------------------------
-- Admins build a gate route with the in-game editor, then save it here under a
-- name. Layouts persist in layouts.json across server restarts and are keyed
-- by the BeamNG level name; the UI only ever sees layouts for the map this
-- server is currently hosting. Loading a layout broadcasts the checkpoints to
-- every connected client at once so the whole grid races the same track.
local LAYOUTS_DIR  = 'Resources/Server/RaceManager'
local LAYOUTS_FILE = LAYOUTS_DIR .. '/layouts.json'
local MAX_LAYOUT_NAME = 40
local layouts = nil  -- lazy-loaded array of { name, map, width, checkpoints }

-- Self-contained JSON encode/decode for the layouts file. Util.JsonEncode is
-- still used for network payloads, but persistence gets its own (strict,
-- mock-independent) codec so the headless tests exercise the real file format.
local function jsonStringify(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return string.format('%.10g', v) end
  if t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function (c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      if c == '\n' then return '\\n' end
      if c == '\r' then return '\\r' end
      if c == '\t' then return '\\t' end
      return string.format('\\u%04x', c:byte())
    end) .. '"'
  end
  if t == 'table' then
    local parts = {}
    if #v > 0 or next(v) == nil then  -- array (empty tables encode as [])
      for _, item in ipairs(v) do parts[#parts + 1] = jsonStringify(item) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, item in pairs(v) do
      if type(k) == 'string' then
        parts[#parts + 1] = jsonStringify(k) .. ':' .. jsonStringify(item)
      end
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function jsonParse(text)
  local pos = 1
  local function err(msg) error(('json: %s at %d'):format(msg, pos), 0) end
  local function ws() pos = text:match('^[ \t\r\n]*()', pos) end
  local parseValue
  local function parseString()
    pos = pos + 1
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == '' then err('unterminated string') end
      if c == '"' then pos = pos + 1; break end
      if c == '\\' then
        local e = text:sub(pos + 1, pos + 1)
        if e == 'u' then
          local hex = text:sub(pos + 2, pos + 5)
          local cp = tonumber(hex, 16) or err('bad \\u escape')
          out[#out + 1] = cp < 128 and string.char(cp) or '?'
          pos = pos + 6
        else
          local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f' }
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parseValue = function ()
    ws()
    local c = text:sub(pos, pos)
    if c == '"' then return parseString() end
    if c == '{' then
      pos = pos + 1
      local obj = {}
      ws()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        ws()
        if text:sub(pos, pos) ~= '"' then err('expected key') end
        local k = parseString()
        ws()
        if text:sub(pos, pos) ~= ':' then err('expected :') end
        pos = pos + 1
        obj[k] = parseValue()
        ws()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == '}' then return obj end
        if sep ~= ',' then err('expected , or }') end
      end
    end
    if c == '[' then
      pos = pos + 1
      local arr = {}
      ws()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parseValue()
        ws()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == ']' then return arr end
        if sep ~= ',' then err('expected , or ]') end
      end
    end
    local lit = text:match('^true', pos) or text:match('^false', pos) or text:match('^null', pos)
    if lit then
      pos = pos + #lit
      if lit == 'true' then return true elseif lit == 'false' then return false end
      return nil
    end
    local num, nextPos = text:match('^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)()', pos)
    if num then pos = nextPos; return tonumber(num) or err('bad number') end
    err('unexpected character')
  end
  local v = parseValue()
  ws()
  return v
end

-- The BeamMP server config names the hosted level as "/levels/<name>/info.json";
-- everything is normalized down to the bare level name ("gridmap_v2") so saved
-- layouts compare cleanly no matter which form the API returns.
local function normalizeMapName(raw)
  if type(raw) ~= 'string' then return nil end
  local name = raw:match('/?[Ll]evels/([^/]+)') or raw
  name = name:gsub('%.json$', ''):gsub('/info$', ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return nil end
  return name
end

local function getCurrentMap()
  -- Primary: the BeamMP settings API.
  if MP.Get and MP.Settings and MP.Settings.Map ~= nil then
    local ok, raw = pcall(MP.Get, MP.Settings.Map)
    local name = ok and normalizeMapName(raw)
    if name then return name end
  end
  -- Fallback: parse ServerConfig.toml in the server's working directory.
  local f = io.open('ServerConfig.toml', 'r')
  if f then
    for line in f:lines() do
      local raw = line:match('^%s*Map%s*=%s*"([^"]*)"')
      if raw then
        f:close()
        return normalizeMapName(raw) or 'unknown'
      end
    end
    f:close()
  end
  return 'unknown'
end

local function ensureLayoutsDir()
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(LAYOUTS_DIR)
  else
    os.execute('mkdir -p "' .. LAYOUTS_DIR .. '"')
  end
end

local function loadLayoutsFromDisk()
  local f = io.open(LAYOUTS_FILE, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. LAYOUTS_FILE .. ', starting with no layouts')
    return {}
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string' and type(l.map) == 'string'
        and type(l.checkpoints) == 'table' and #l.checkpoints > 0 then
      out[#out + 1] = l
    end
  end
  return out
end

local function getLayouts()
  if not layouts then
    layouts = loadLayoutsFromDisk()
    print('[RaceManager] Loaded ' .. #layouts .. ' saved layout(s) from ' .. LAYOUTS_FILE)
  end
  return layouts
end

local function saveLayoutsToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(LAYOUTS_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({ version = 1, layouts = getLayouts() }))
  f:close()
  return true
end

-- Checkpoints as the client editor stores them: position + normalized travel
-- heading (the gate's rotation) + the shared gate dimensions saved per layout.
-- Per-checkpoint width/height overrides are optional and only kept when
-- present, so a gate with no override inherits the layout-wide defaults.
-- The same shape describes a start position (a placement + a facing), so the
-- starting grid goes through this too.
local function sanitizeCheckpoints(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, cp in ipairs(raw) do
    if type(cp) ~= 'table' then return nil end
    local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
    if not (x and y and z) then return nil end
    out[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
    if tonumber(cp.width)  then out[i].width  = tonumber(cp.width)  end
    if tonumber(cp.height) then out[i].height = tonumber(cp.height) end
  end
  if #out == 0 then return nil end
  return out
end

-- Strict map filter: the UI only ever sees layouts saved for the map this
-- server is hosting right now.
local function layoutsForCurrentMap()
  local map = getCurrentMap()
  local list = {}
  for _, l in ipairs(getLayouts()) do
    if l.map == map then list[#list + 1] = l end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)
  return list, map
end

local function sendLayoutList(targetPid)
  local list, map = layoutsForCurrentMap()
  local gates = 0
  for _, l in ipairs(list) do gates = gates + #l.checkpoints end
  print(string.format('[RaceManager] Sending layout list to %s: %d layout(s), %d gate(s) total, map %s',
    targetPid and tostring(targetPid) or 'all', #list, gates, map))
  MP.TriggerClientEvent(targetPid or -1, 'RM_Layouts',
    Util.JsonEncode({ map = map, layouts = list }))
end

function RM_onRequestLayouts(pid)
  sendLayoutList(pid)
end

-- Strict track-state purge. Drops the in-memory layout cache (the next access
-- re-reads layouts.json from disk, so nothing stale survives in a global) and
-- orders every client to delete its checkpoint arrays and 3D gate visuals.
-- Broadcast on server boot and immediately before a new layout is applied, so
-- ghost checkpoints from an earlier session can never leak into a new one.
local function clearTrackState(reason)
  layouts = nil
  MP.TriggerClientEvent(-1, 'RM_ClearTrack', Util.JsonEncode({ reason = reason or 'clear' }))
  print('[RaceManager] Track state cleared: ' .. (reason or 'clear'))
end

-- Client/UI asked for an explicit full clear (also refreshes everyone's list).
function RM_onClearTrackState(pid)
  if not requireAuth(pid) then return end
  clearTrackState('requested by ' .. (MP.GetPlayerName(pid) or pid))
  sendLayoutList(-1)
end

-- Save the checkpoints the client bundled up as a named layout for the current
-- map. Same name on the same map overwrites (that's the edit workflow); the
-- refreshed list goes to every client so all open UIs stay in sync.
-- Every rejection branch logs its reason so a dropped save is diagnosable.
function RM_onSaveLayout(pid, rawData)
  if not requireAuth(pid) then return end
  print(string.format('[RaceManager] RM_SaveLayout from %s: %s byte(s)',
    MP.GetPlayerName(pid) or pid, type(rawData) == 'string' and #rawData or 'non-string'))
  if type(rawData) ~= 'string' or rawData == '' then
    print('[RaceManager] Save rejected: empty payload')
    return
  end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Save rejected: JSON decode failed (' .. tostring(data) .. ')')
    return
  end

  local name = type(data.name) == 'string'
    and data.name:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, MAX_LAYOUT_NAME) or ''
  local checkpoints = sanitizeCheckpoints(data.checkpoints)
  if name == '' then
    print('[RaceManager] Save rejected: missing/empty layout name')
    return
  end
  if not checkpoints then
    print('[RaceManager] Save rejected: checkpoint array missing or malformed')
    return
  end

  local map = getCurrentMap()
  local starts = sanitizeCheckpoints(data.startPositions)
  local entry = {
    name        = name,
    map         = map,
    width       = tonumber(data.width)  or 20,
    height      = tonumber(data.height) or 10,
    checkpoints = checkpoints,
    -- Optional rallycross joker route (Module 2): a second, independent gate
    -- set stored with the layout. Absent on plain circuits.
    joker       = sanitizeCheckpoints(data.joker),
    -- Optional starting grid: where the cars line up for this track.
    startPositions = starts,
  }
  -- Saving is also the moment the server learns this track's grid size, so the
  -- "more drivers than start positions" warning is accurate straight away.
  race.startSlots = starts and #starts or 0
  broadcastState()
  local all = getLayouts()
  local replaced = false
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      all[i] = entry
      replaced = true
      break
    end
  end
  if not replaced then all[#all + 1] = entry end

  local wrote, werr = saveLayoutsToDisk()
  if not wrote then
    print('[RaceManager] Failed to write ' .. LAYOUTS_FILE .. ': ' .. tostring(werr))
    return
  end
  local msg = string.format('[RaceManager] Layout "%s" (%d gates%s%s, %s) %s by %s',
    name, #checkpoints,
    entry.joker and (' + ' .. #entry.joker .. ' joker gates') or '',
    starts and (' + ' .. #starts .. ' start positions') or '',
    map, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid)
  MP.SendChatMessage(-1, msg)
  print(msg)
  sendLayoutList(-1)
end

-- Load a saved layout: look it up under the current map only and broadcast the
-- checkpoint set to every connected client, which instantly rebuilds its gates.
-- Locked once a countdown/race is under way — nobody swaps the track mid-race.
function RM_onLoadLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local list, map = layoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- Purge first: every client must drop its existing gates before the new
      -- set arrives, so no checkpoint from a previous layout can survive.
      clearTrackState('loading layout "' .. l.name .. '"')
      -- The grid this track was saved with is now the grid the session uses.
      race.startSlots = (type(l.startPositions) == 'table') and #l.startPositions or 0
      print(string.format('[RaceManager] Broadcasting RM_ApplyLayout: "%s", %d checkpoint(s), %d start position(s), width %s',
        l.name, #l.checkpoints, race.startSlots, tostring(l.width)))
      MP.TriggerClientEvent(-1, 'RM_ApplyLayout', Util.JsonEncode(l))
      local msg = string.format('[RaceManager] Layout "%s" loaded on %s by %s (%d gates, %d start positions)',
        l.name, map, MP.GetPlayerName(pid) or pid, #l.checkpoints, race.startSlots)
      MP.SendChatMessage(-1, msg)
      print(msg)
      return
    end
  end
  print(string.format('[RaceManager] Load failed: no layout "%s" for map %s', data.name, map))
end

-- ---------------------------------------------------------------------------
-- Module 4: "BeamJoy" vehicle & setup locking (the Garage List)
-- ---------------------------------------------------------------------------
-- An admin drives the car they want to allow, presses "Whitelist Current
-- Vehicle", and the client captures that vehicle's exact configuration (model
-- + full part config + tuning variables) as a signature string. Repeat to build
-- a Garage List of allowed cars.
--
-- Enforcement has two layers, because the server has no physics/vehicle
-- introspection of its own:
--   1. BeamMP's onVehicleSpawn / onVehicleEdited hooks: the raw payload carries
--      the jbeam model name ("jbm"), so a car whose *model* is not on the list
--      is cancelled outright before it ever exists for other players.
--   2. RM_VehicleConfig: the client reports the exact signature of every
--      vehicle it spawns or re-tunes. A signature that is not on the list gets
--      the vehicle removed and an error pushed to that player's UI.
-- Authenticated admins are exempt — otherwise an admin could never spawn the
-- car they are about to whitelist.
local GARAGE_FILE        = LAYOUTS_DIR .. '/garage.json'
local MAX_GARAGE_ENTRIES = 60
local MAX_SIG_LENGTH     = 4000

local garage = {
  enforce = false,   -- master switch for the whole rule
  -- { { model = 'etk800', label = 'ETK 800 - Race', sig = '...', game = '0.39' } }
  -- `game` is the BeamNG build the entry was captured on. A game update can
  -- rename vehicle parts without the car changing (BeamNG v0.39 did exactly
  -- that), and a renamed part changes the signature, so every entry captured on
  -- an earlier build stops matching. Storing the build is what lets a rejection
  -- say "this list was captured on an older game version, re-capture it"
  -- instead of leaving a driver rejected with no explanation. Entries written
  -- before this field existed simply have no `game`, and are never treated as a
  -- mismatch on that basis.
  list    = {},
}
local garageLoaded = false

local function loadGarageFromDisk()
  local f = io.open(GARAGE_FILE, 'r')
  if not f then return end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Could not parse ' .. GARAGE_FILE .. ', starting with an empty garage')
    return
  end
  garage.enforce = data.enforce == true
  garage.list = {}
  for _, e in ipairs(type(data.list) == 'table' and data.list or {}) do
    if type(e) == 'table' and type(e.sig) == 'string' and e.sig ~= '' then
      garage.list[#garage.list + 1] = {
        model = tostring(e.model or '?'),
        label = tostring(e.label or e.model or 'Vehicle'),
        sig   = e.sig,
        game  = (type(e.game) == 'string' and e.game ~= '') and e.game or nil,
      }
    end
  end
end

local function getGarage()
  if not garageLoaded then
    garageLoaded = true
    loadGarageFromDisk()
    print('[RaceManager] Garage list: ' .. #garage.list .. ' approved vehicle(s), enforcement '
      .. (garage.enforce and 'ON' or 'off'))
  end
  return garage
end

local function saveGarageToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(GARAGE_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({ version = 1, enforce = getGarage().enforce, list = getGarage().list }))
  f:close()
  return true
end

-- Assigned to the forward-declared local near broadcastState so every state
-- broadcast can carry the current Garage List without the racing code knowing
-- how it is stored.
garageSnapshot = function ()
  local g = getGarage()
  -- Signatures can be long; the UI only ever displays model/label, so ship a
  -- compact view (the signature stays server-side).
  local list = {}
  for i, e in ipairs(g.list) do
    list[i] = { model = e.model, label = e.label }
  end
  return { list = list, enforce = g.enforce }
end

-- Enforcement only bites when it is switched on AND at least one car has been
-- captured — an empty whitelist would otherwise lock every player out.
local function garageEnforcing()
  local g = getGarage()
  return g.enforce and #g.list > 0
end

local function garageHasSig(sig)
  for _, e in ipairs(getGarage().list) do
    if e.sig == sig then return true end
  end
  return false
end

local function garageHasModel(model)
  if not model or model == '' then return false end
  model = model:lower()
  for _, e in ipairs(getGarage().list) do
    if tostring(e.model):lower() == model then return true end
  end
  return false
end

-- A signature mismatch on a car whose MODEL is approved is the shape a stale
-- Garage List takes after a BeamNG update that renamed vehicle parts: the
-- driver is in an allowed car, but the stored signature was built from part
-- names the game no longer uses. When the entry was captured on a different
-- build than the driver is running, say so — the admin has to re-capture, and
-- nothing on the server can work that out for them. Returns nil when the
-- versions match, are unknown, or the model was never approved in the first
-- place, so an ordinary "you tuned a car that isn't allowed" rejection keeps
-- its plain wording.
local function garageVersionSkew(model, clientGame)
  if type(clientGame) ~= 'string' or clientGame == '' then return nil end
  if not model or model == '' then return nil end
  local wanted = model:lower()
  for _, e in ipairs(getGarage().list) do
    if tostring(e.model):lower() == wanted and type(e.game) == 'string'
        and e.game ~= '' and e.game ~= clientGame then
      return e
    end
  end
  return nil
end

local function rejectVehicle(pid, vid, why)
  if MP.RemoveVehicle and vid then
    pcall(MP.RemoveVehicle, pid, vid)
  end
  MP.TriggerClientEvent(pid, 'RM_VehicleRejected', Util.JsonEncode({
    message = 'Vehicle/Setup not allowed in this session.',
    detail  = why or '',
  }))
  print(string.format('[RaceManager] Rejected vehicle from %s (%s)',
    MP.GetPlayerName(pid) or pid, why or 'not on the Garage List'))
end

-- Admin captured the car they are currently driving.
function RM_onWhitelistVehicle(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Whitelist rejected: undecodable payload')
    return
  end
  local sig = data.sig and tostring(data.sig) or ''
  if sig == '' or #sig > MAX_SIG_LENGTH then
    print('[RaceManager] Whitelist rejected: missing or oversized configuration signature')
    return
  end
  local g = getGarage()
  if garageHasSig(sig) then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'That exact vehicle/setup is already on the Garage List',
    }))
    return
  end
  if #g.list >= MAX_GARAGE_ENTRIES then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'Garage List is full (' .. MAX_GARAGE_ENTRIES .. ' entries)',
    }))
    return
  end
  local entry = {
    model = tostring(data.model or '?'),
    label = tostring(data.label or data.model or 'Vehicle'),
    sig   = sig,
    game  = (type(data.game) == 'string' and data.game ~= '') and data.game or nil,
  }
  g.list[#g.list + 1] = entry
  local wrote, werr = saveGarageToDisk()
  if not wrote then print('[RaceManager] Failed to write ' .. GARAGE_FILE .. ': ' .. tostring(werr)) end
  MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
    added = true, message = 'Added "' .. entry.label .. '" to the Garage List',
  }))
  local msg = string.format('[RaceManager] "%s" added to the Garage List by %s (%d approved)',
    entry.label, MP.GetPlayerName(pid) or pid, #g.list)
  MP.SendChatMessage(-1, msg)
  print(msg)
  broadcastState()
end

function RM_onClearGarage(pid)
  if not requireAuth(pid) then return end
  local g = getGarage()
  local n = #g.list
  g.list = {}
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] Garage List cleared by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. n .. ' entr' .. (n == 1 and 'y' or 'ies') .. ' removed)')
end

-- Drop a single approved car by its position in the list.
function RM_onRemoveGarageEntry(pid, rawData)
  if not requireAuth(pid) then return end
  local idx = decodeNumber(rawData, 'index')
  if not idx then return end
  idx = math.floor(idx)
  local g = getGarage()
  if idx < 1 or idx > #g.list then return end
  local removed = table.remove(g.list, idx)
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] "' .. removed.label .. '" removed from the Garage List by '
    .. (MP.GetPlayerName(pid) or pid))
end

function RM_onSetGarageEnforce(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  getGarage().enforce = data.enabled == true or data.enabled == 1
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] Garage enforcement '
    .. (garage.enforce and 'ENABLED' or 'disabled') .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client reported the exact configuration of a vehicle it just spawned or
-- re-tuned. This is the strict check: the signature must be on the list.
function RM_onVehicleConfig(pid, rawData)
  if not garageEnforcing() then return end
  if isAuthenticated(pid) then return end  -- admins build the list, exempt
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local sig = data.sig and tostring(data.sig) or ''
  if sig ~= '' and garageHasSig(sig) then return end
  local model = data.model and tostring(data.model) or ''
  local stale = garageVersionSkew(model, data.game and tostring(data.game) or nil)
  if stale then
    rejectVehicle(pid, tonumber(data.vid), 'the Garage List entry for "' .. stale.label
      .. '" was captured on BeamNG ' .. stale.game .. ' and you are on '
      .. tostring(data.game) .. ' — a game update can rename vehicle parts, so an '
      .. 'admin needs to re-capture the Garage List')
    return
  end
  rejectVehicle(pid, tonumber(data.vid), 'setup signature not on the Garage List')
end

-- BeamMP spawn/edit hooks. The payload is the raw vehicle packet; the jbeam
-- model name is enough to cancel an obviously-disallowed car immediately
-- (returning 1 tells BeamMP to drop the spawn). Returning nothing allows it,
-- and the RM_VehicleConfig check above still has the final word on the setup.
local function garageModelFromPacket(data)
  if type(data) ~= 'string' then return nil end
  return data:match('"jbm"%s*:%s*"([^"]*)"')
end

function RM_onVehicleSpawn(pid, vid, data)
  if not garageEnforcing() then return end
  if isAuthenticated(pid) then return end
  local model = garageModelFromPacket(data)
  if model and not garageHasModel(model) then
    rejectVehicle(pid, vid, 'vehicle "' .. model .. '" is not on the Garage List')
    return 1  -- cancel the spawn
  end
end

function RM_onVehicleEdited(pid, vid, data)
  if not garageEnforcing() then return end
  if isAuthenticated(pid) then return end
  local model = garageModelFromPacket(data)
  if model and not garageHasModel(model) then
    rejectVehicle(pid, vid, 'edited into "' .. model .. '", which is not on the Garage List')
    return 1  -- cancel the edit
  end
end

-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Completely independent of the circuit racing state machine above: its own
-- state tables, its own event names (RM_Derby*), its own broadcast channel
-- (RM_DerbyUpdate), its own tick timer and its own results file. Nothing in
-- this section reads or writes `race`, `players`, `lapFirsts` or the layout
-- store, so derby sessions can never disturb qualifying/racing and vice versa.
--
-- Flow: admin tunes the two timers and drops boundary markers (clients send
-- their vehicle position via RM_DerbyAddMarker), then Start Derby snapshots
-- every connected player as an active participant. Clients police themselves
-- (point-in-polygon + stopped-vehicle detection happen client-side, where the
-- physics live) and report RM_DerbyDisqualified / RM_DerbyDemolished; the
-- server is authoritative for the participant list, elimination order, the
-- last-man-standing win condition and the results .txt export.

local DERBY_DEFAULT_OOB_LIMIT  = 5    -- seconds allowed outside the boundary
local DERBY_DEFAULT_DEMO_LIMIT = 10   -- seconds stopped before demolished
local DERBY_MIN_LIMIT          = 1
local DERBY_MAX_LIMIT          = 120
local DERBY_TICK_MS            = 1000 -- derby clock resolution (1 s is plenty)
local DERBY_MAX_MARKERS        = 64

local DERBY_UNLIMITED_RESETS = -1
local DERBY_MAX_RESET_LIMIT  = 99
local DERBY_MAX_STARTS       = 64

local derby = {
  phase     = 'idle',   -- idle | running | finished
  -- Who is in a derby. 'all' (the default) is the historical behaviour: every
  -- connected session becomes a participant. 'join' honours the same Join Race
  -- opt-in the circuit races use, so somebody who only wants to watch is not
  -- dragged in -- being entered means losing your car to freecam the moment you
  -- are eliminated, which is a poor thing to do to a spectator.
  --
  -- This READS the racing entry list rather than keeping a second one: players
  -- would otherwise have to opt in twice for no benefit. It is a read, so the
  -- derby still never mutates racing state.
  entryMode = 'all',    -- all | join
  oobLimit  = DERBY_DEFAULT_OOB_LIMIT,
  demoLimit = DERBY_DEFAULT_DEMO_LIMIT,
  maxResets = DERBY_UNLIMITED_RESETS,  -- vehicle resets per driver per derby
  time      = 0,        -- seconds since Start Derby (advanced by RM_DerbyTick)
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  startPositions = {},  -- derby starting grid { x, y, z, hx, hy }, slot 1 first
  winner    = nil,      -- winner's name once decided
}
local derbyPlayers = {} -- [pid] = { id, name, status, reason, elimTime, resets }
                        -- status: alive | eliminated | winner
-- Derby countdown. Its own value and its own client event, deliberately not
-- shared with the racing countdown: the two start procedures are independent
-- and neither may release the other's held cars.
local DERBY_COUNTDOWN_FROM = 3
local derbyCountdownValue  = nil

local function broadcastDerbyCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_DerbyCountdown', Util.JsonEncode({ count = count }))
end

-- A derby is "active" from the moment the field is formed up, not just while it
-- is running. Setup actions -- editing the arena, changing the rules, loading a
-- saved arena -- are locked for all three phases: once cars are standing on
-- their slots and held, the ground must not move under them. Gameplay checks
-- (elimination, reset counting, the tick) stay strictly 'running', because none
-- of that should happen before GO.
local function derbyActive()
  return derby.phase == 'forming'
      or derby.phase == 'countdown'
      or derby.phase == 'running'
end

local function derbyClampLimit(n, default)
  n = tonumber(n)
  if not n then return default end
  if n < DERBY_MIN_LIMIT then return DERBY_MIN_LIMIT end
  if n > DERBY_MAX_LIMIT then return DERBY_MAX_LIMIT end
  return n
end

-- Participants ordered for display/results: winner first, then survivors,
-- then eliminated players latest-out first (2nd place = last one eliminated).
-- How many players would be in a derby started right now. While one is running
-- that is simply the field it started with; otherwise it depends on the entry
-- mode, so the admin can see an empty opt-in list before pressing Start.
local function derbyEligibleCount()
  if derbyActive() then
    local n = 0
    for _ in pairs(derbyPlayers) do n = n + 1 end
    return n
  end
  local n = 0
  -- onlinePlayers() rather than MP.GetPlayers() directly: this reads the racing
  -- entry list by id, and an id that does not compare equal to the key that
  -- record is stored under reads as "has not joined" for every driver on the
  -- server -- the same way it emptied the race grid.
  for id in pairs(onlinePlayers()) do
    local rec = players[id]
    if derby.entryMode ~= 'join' or (rec and rec.joined) then n = n + 1 end
  end
  return n
end

local function derbyClassification()
  local list = {}
  for _, rec in pairs(derbyPlayers) do
    -- Carry the display name onto the derby board. Re-read from the racing
    -- record every time rather than merging: a stamped value would go sticky
    -- and a name the admin CLEARED would never disappear from the standings.
    local owner = players[rec.id]
    rec.alias = owner and owner.alias or nil
    list[#list + 1] = rec
  end
  table.sort(list, function (a, b)
    local rank = { winner = 0, alive = 1, eliminated = 2 }
    local ra, rb = rank[a.status] or 3, rank[b.status] or 3
    if ra ~= rb then return ra < rb end
    if ra == 2 and a.elimTime ~= b.elimTime then return a.elimTime > b.elimTime end
    return a.id < b.id
  end)
  return list
end

local function broadcastDerbyState(targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_DerbyUpdate', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    derbyPhase = derby.phase,
    entryMode  = derby.entryMode,
    -- How many would take part if the derby started right now, so the admin can
    -- see an empty opt-in field before pressing Start rather than after.
    entrants   = derbyEligibleCount(),
    oobLimit   = derby.oobLimit,
    demoLimit  = derby.demoLimit,
    maxResets  = derby.maxResets,
    derbyTime  = derby.time,
    boundary   = derby.boundary,
    startPositions = derby.startPositions,
    winner     = derby.winner,
    players    = derbyClassification(),
  }))
end

-- Fills the forward declaration made up beside the racing entry list. Has to be
-- assigned down HERE, after broadcastDerbyState exists, or the closure would
-- capture a nil. Only matters outside a running derby: once one is under way
-- the field is fixed and the count is whatever it started with.
derbyEntryListChanged = function ()
  if not derbyActive() then broadcastDerbyState() end
end

local function derbyFmtTime(t)
  if not t then return '--:--' end
  local m = math.floor(t / 60)
  return string.format('%d:%02d', m, math.floor(t - m * 60))
end

local function buildDerbyResultsText()
  local list = derbyClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add('==================================================')
  add(' RACE MANAGER - DEMO DERBY RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Duration: %s | Drivers: %d | OOB limit: %gs | Stop limit: %gs',
    derbyFmtTime(derby.time), #list, derby.oobLimit, derby.demoLimit))
  add('==================================================')
  add('')
  -- The resets column only appears when the derby actually limited them.
  local resetCol = derby.maxResets >= 0 and string.format(' %-6s', 'Resets') or ''
  add(string.format('%-5s %-22s %-14s %-13s%s', 'Pos', 'Driver', 'Result', 'Eliminated At', resetCol))
  for i, rec in ipairs(list) do
    local result, elimAt
    if rec.status == 'winner' then
      result, elimAt = 'WINNER', 'survived'
    elseif rec.status == 'alive' then
      result, elimAt = 'Still running', '-'
    else
      result, elimAt = rec.reason or 'Eliminated', derbyFmtTime(rec.elimTime)
    end
    local resetVal = derby.maxResets >= 0
      and string.format(' %-6s', (rec.resets or 0) .. '/' .. derby.maxResets) or ''
    local tag = rec.status == 'winner' and '  << LAST MAN STANDING' or ''
    add(string.format('P%-4d %-22s %-14s %-13s%s%s%s',
      i, displayName(rec), result, elimAt, resetVal, aliasNote(rec), tag))
  end
  if #list == 0 then add('(no drivers)') end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeDerbyResults()
  ensureResultsDir()
  local path = uniqueResultsPath('derby_results')
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(buildDerbyResultsText())
  f:close()
  return true, path
end

-- Every driver in the derby gets their car back, through the same staggered,
-- ghosted respawn the racing side uses.
--
-- A derby ends with almost the WHOLE field removed -- that is what a derby is,
-- everyone but the last man standing has been eliminated and is watching from
-- freecam -- so it is the heaviest mass respawn in the mod, and it was the one
-- still firing a bare broadcast that put every car back on the same tick. That
-- is exactly the refused-spawn-and-interpenetration case the ordering exists to
-- prevent.
--
-- The field is snapshotted here and handed to respawnField, so the mechanism is
-- shared while the isolation is not broken: this reads derbyPlayers only, never
-- the racing tables. Elimination order is deliberately NOT the spawn order --
-- drivers return to slots handed out by ascending id at form-up, so coming back
-- in that same order puts them back the way they lined up.
local function respawnDerbyField()
  local participants = {}
  for _, rec in pairs(derbyPlayers) do
    participants[#participants + 1] = rec
  end
  table.sort(participants, function (a, b) return a.id < b.id end)
  respawnField('derby', participants)
end

-- Single exit point for every way a derby ends (last man standing, admin
-- ended, everyone eliminated): stop the clock, export results, announce.
local function finishDerby(reason)
  derby.phase = 'finished'
  MP.CancelEventTimer('RM_DerbyTick')
  -- The derby is over: every eliminated driver gets their car and camera back.
  -- Scoped to the 'derby' source so a racing DNF's spectator lock is untouched.
  respawnDerbyField()
  broadcastDerbyState()
  print('[RaceManager] Derby over: ' .. reason)
  local ok, wrote, pathOrErr = pcall(writeDerbyResults)
  if ok and wrote then
    local msg = derby.winner
      and ('[RaceManager] DEMO DERBY WINNER: ' .. derby.winner .. '! Results saved: ' .. pathOrErr)
      or  ('[RaceManager] Demo derby over (' .. reason .. '). Results saved: ' .. pathOrErr)
    MP.SendChatMessage(-1, msg)
    print('[RaceManager] Derby results written to ' .. pathOrErr)
  else
    print('[RaceManager] Failed to write derby results: ' .. tostring(ok and pathOrErr or wrote))
  end
end

-- Eliminate one participant; when exactly one is left standing the derby ends
-- itself and crowns the survivor.
local function derbyEliminate(pid, reason)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end  -- duplicate reports are no-ops
  rec.status   = 'eliminated'
  rec.reason   = reason
  rec.elimTime = derby.time
  -- Forced spectator mode (Module 1): an eliminated driver loses their car and
  -- their camera goes to freecam until the derby ends. This only *sends* a
  -- client event — no racing state is read or written, so the isolation of this
  -- module is intact.
  forceSpectate(pid, reason .. ' — you are out of this derby', 'derby')
  print(string.format('[RaceManager] Derby: %s eliminated (%s) at %s',
    rec.name, reason, derbyFmtTime(derby.time)))

  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = displayName(lastAlive)
    finishDerby('last man standing: ' .. displayName(lastAlive))
  elseif alive == 0 then
    finishDerby('no survivors')
  else
    broadcastDerbyState()
  end
end

-- --- Derby event handlers (admin controls relayed by the client bridge) ----

function RM_onDerbySetConfig(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  derby.oobLimit  = derbyClampLimit(data.oobLimit,  derby.oobLimit)
  derby.demoLimit = derbyClampLimit(data.demoLimit, derby.demoLimit)
  -- Reset allowance, mirroring the race rule: negative = unlimited, 0 = none.
  local resets = tonumber(data.maxResets)
  if resets then
    resets = math.floor(resets)
    if resets < 0 then resets = DERBY_UNLIMITED_RESETS
    elseif resets > DERBY_MAX_RESET_LIMIT then resets = DERBY_MAX_RESET_LIMIT end
    derby.maxResets = resets
  end
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby config by %s: OOB %gs, stop %gs, resets %s',
    MP.GetPlayerName(pid) or pid, derby.oobLimit, derby.demoLimit,
    derby.maxResets < 0 and 'unlimited' or tostring(derby.maxResets)))
end

-- Admin dropped a boundary marker at their vehicle's position; the ordered
-- marker list is the arena polygon every client runs point-in-polygon against.
function RM_onDerbyAddMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if #derby.boundary >= DERBY_MAX_MARKERS then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.boundary[#derby.boundary + 1] = { x = x, y = y, z = z }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d placed by %s at %.1f, %.1f',
    #derby.boundary, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyClearBoundary(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.boundary = {}
  broadcastDerbyState()
  print('[RaceManager] Derby boundary cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Admin dropped a derby start position at their vehicle's placement (position
-- + facing). Slot 1 is placed first; Start Derby hands one slot per driver.
function RM_onDerbyAddStart(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if #derby.startPositions >= DERBY_MAX_STARTS then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.startPositions[#derby.startPositions + 1] = {
    x = x, y = y, z = z,
    hx = tonumber(data.hx) or 0, hy = tonumber(data.hy) or 1,
  }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby start position %d placed by %s at %.1f, %.1f',
    #derby.startPositions, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyClearStarts(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.startPositions = {}
  broadcastDerbyState()
  print('[RaceManager] Derby start grid cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client spent one of its derby resets (the client polices the allowance, the
-- server keeps the tally the standings show).
function RM_onDerbyVehicleReset(pid)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end
  if derby.maxResets >= 0 and (rec.resets or 0) >= derby.maxResets then return end
  rec.resets = (rec.resets or 0) + 1
  print(string.format('[RaceManager] Derby: %s used reset %d/%s',
    rec.name, rec.resets, derby.maxResets < 0 and '∞' or tostring(derby.maxResets)))
  broadcastDerbyState()
end

-- Client blocked a derby reset the driver was no longer entitled to. Logged
-- only — the block itself already happened client-side and costs nothing.
function RM_onDerbyResetDenied(pid)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec then return end
  print(string.format('[RaceManager] Derby: %s reset BLOCKED (allowance %s spent)',
    rec.name, derby.maxResets < 0 and 'unlimited' or tostring(derby.maxResets)))
end

-- ---------------------------------------------------------------------------
-- Derby arena layouts: persistent, per-map, same workflow as track layouts
-- ---------------------------------------------------------------------------
-- An arena is its boundary polygon plus the two timers. Admins build one with
-- the marker tool, save it under a name, and load it back on a later session —
-- loading broadcasts the boundary to every client at once, exactly the way a
-- track layout does. Stored in its own file so the derby module keeps owning
-- its own persistence.
local DERBY_LAYOUTS_FILE = LAYOUTS_DIR .. '/derbyArenas.json'
local derbyLayouts = nil   -- lazy-loaded array of { name, map, boundary, ... }

local function loadDerbyLayoutsFromDisk()
  local f = io.open(DERBY_LAYOUTS_FILE, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. DERBY_LAYOUTS_FILE .. ', starting with no arenas')
    return {}
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string' and type(l.map) == 'string'
        and type(l.boundary) == 'table' and #l.boundary >= 3 then
      out[#out + 1] = l
    end
  end
  return out
end

local function getDerbyLayouts()
  if not derbyLayouts then
    derbyLayouts = loadDerbyLayoutsFromDisk()
    print('[RaceManager] Loaded ' .. #derbyLayouts .. ' saved derby arena(s) from '
      .. DERBY_LAYOUTS_FILE)
  end
  return derbyLayouts
end

local function saveDerbyLayoutsToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(DERBY_LAYOUTS_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({ version = 1, layouts = getDerbyLayouts() }))
  f:close()
  return true
end

-- Boundary markers are plain points; no heading, no dimensions.
local function sanitizeBoundary(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, m in ipairs(raw) do
    if type(m) ~= 'table' then return nil end
    local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
    if not (x and y and z) then return nil end
    if i > DERBY_MAX_MARKERS then break end
    out[i] = { x = x, y = y, z = z }
  end
  if #out < 3 then return nil end
  return out
end

local function derbyLayoutsForCurrentMap()
  local map = getCurrentMap()
  local list = {}
  for _, l in ipairs(getDerbyLayouts()) do
    if l.map == map then list[#list + 1] = l end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)
  return list, map
end

local function sendDerbyLayoutList(targetPid)
  local list, map = derbyLayoutsForCurrentMap()
  MP.TriggerClientEvent(targetPid or -1, 'RM_DerbyLayouts',
    Util.JsonEncode({ map = map, layouts = list }))
  print(string.format('[RaceManager] Sending derby arena list to %s: %d arena(s), map %s',
    targetPid and tostring(targetPid) or 'all', #list, map))
end

function RM_onDerbyRequestLayouts(pid)
  sendDerbyLayoutList(pid)
end

-- Save the current boundary + timers as a named arena for this map. Same name
-- on the same map overwrites, which is the edit workflow.
function RM_onDerbySaveLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Derby arena save rejected: JSON decode failed')
    return
  end
  local name = type(data.name) == 'string'
    and data.name:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, MAX_LAYOUT_NAME) or ''
  local boundary = sanitizeBoundary(data.boundary)
  if name == '' then
    print('[RaceManager] Derby arena save rejected: missing name')
    return
  end
  if not boundary then
    print('[RaceManager] Derby arena save rejected: needs at least 3 valid markers')
    return
  end

  local resets = tonumber(data.maxResets)
  if resets then
    resets = math.floor(resets)
    if resets < 0 then resets = DERBY_UNLIMITED_RESETS
    elseif resets > DERBY_MAX_RESET_LIMIT then resets = DERBY_MAX_RESET_LIMIT end
  end
  local map = getCurrentMap()
  local entry = {
    name      = name,
    map       = map,
    boundary  = boundary,
    oobLimit  = derbyClampLimit(data.oobLimit,  derby.oobLimit),
    demoLimit = derbyClampLimit(data.demoLimit, derby.demoLimit),
    maxResets = resets or derby.maxResets,
    -- Optional starting grid (same placement shape the race grid uses).
    startPositions = sanitizeCheckpoints(data.startPositions),
  }
  local all = getDerbyLayouts()
  local replaced = false
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      all[i] = entry
      replaced = true
      break
    end
  end
  if not replaced then all[#all + 1] = entry end

  local wrote, werr = saveDerbyLayoutsToDisk()
  if not wrote then
    print('[RaceManager] Failed to write ' .. DERBY_LAYOUTS_FILE .. ': ' .. tostring(werr))
    return
  end
  local msg = string.format('[RaceManager] Derby arena "%s" (%d markers, %s) %s by %s',
    name, #boundary, map, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid)
  MP.SendChatMessage(-1, msg)
  print(msg)
  sendDerbyLayoutList(-1)
end

-- Load a saved arena: adopt its boundary and timers, then push the new derby
-- state to every client so their point-in-polygon test uses the new perimeter.
-- Refused while a derby is running — the arena cannot move under the drivers.
function RM_onDerbyLoadLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local list, map = derbyLayoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      derby.boundary  = l.boundary
      derby.oobLimit  = derbyClampLimit(l.oobLimit,  derby.oobLimit)
      derby.demoLimit = derbyClampLimit(l.demoLimit, derby.demoLimit)
      if type(l.maxResets) == 'number' then derby.maxResets = math.floor(l.maxResets) end
      derby.startPositions = sanitizeCheckpoints(l.startPositions) or {}
      broadcastDerbyState()
      local msg = string.format('[RaceManager] Derby arena "%s" loaded on %s by %s (%d markers)',
        l.name, map, MP.GetPlayerName(pid) or pid, #l.boundary)
      MP.SendChatMessage(-1, msg)
      print(msg)
      return
    end
  end
  print(string.format('[RaceManager] Derby arena load failed: no arena "%s" for map %s',
    data.name, map))
end

function RM_onDerbyDeleteLayout(pid, rawData)
  if not requireAuth(pid) then return end
  local name = decodeString(rawData, 'name')
  if not name or name == '' then return end
  local map = getCurrentMap()
  local all = getDerbyLayouts()
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      table.remove(all, i)
      saveDerbyLayoutsToDisk()
      sendDerbyLayoutList(-1)
      print('[RaceManager] Derby arena "' .. l.name .. '" deleted by '
        .. (MP.GetPlayerName(pid) or pid))
      return
    end
  end
end

-- Start Derby: snapshot every connected player as an active participant and
-- start the derby clock. A fresh start from 'finished' wipes the last session.
-- Who takes part in the next derby: everyone connected, or only drivers who
-- opted in with Join Race. Locked while a derby is running -- the field cannot
-- change under the drivers.
function RM_onDerbySetEntryMode(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'all' and mode ~= 'join' then return end
  derby.entryMode = mode
  broadcastDerbyState()
  print('[RaceManager] Derby entry mode set to "' .. mode .. '" by '
    .. (MP.GetPlayerName(pid) or pid))
end

-- Form up: build the field, stand everyone on a slot and HOLD them there until
-- the countdown lets go. The derby's Generate Grid, and the same two-step shape
-- the circuit races use — form the grid, then start it.
function RM_onDerbyFormUp(pid)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' or derby.phase == 'countdown' then return end
  derbyPlayers = {}
  derby.winner = nil
  derby.time   = 0
  local optIn = derby.entryMode == 'join'
  for id in pairs(onlinePlayers()) do
    -- In opt-in mode only drivers who pressed Join Race take part. Read-only
    -- against the racing entry list; a player with no racing record at all has
    -- plainly not joined anything.
    local rec = players[id]
    if (not optIn) or (rec and rec.joined) then
      derbyPlayers[id] = {
        id       = id,
        name     = MP.GetPlayerName(id) or ('Player ' .. id),
        status   = 'alive',
        reason   = nil,
        elimTime = nil,
        resets   = 0,
      }
    end
  end
  local count = 0
  for _ in pairs(derbyPlayers) do count = count + 1 end
  if count == 0 then
    -- Two different reasons, and telling them apart matters: an empty server is
    -- obvious, an empty entry list looks like a broken button.
    if optIn then
      print('[RaceManager] Derby form-up ignored: nobody has joined (opt-in entry is on)')
      MP.SendChatMessage(pid, '[RaceManager] Nobody has joined — press Join Race, '
        .. 'or switch derby entry to Everyone.')
    else
      print('[RaceManager] Derby form-up ignored: no players connected')
    end
    return
  end
  derby.phase = 'forming'
  releaseSpectators('derby')  -- fresh derby: nobody carries a stale penalty
  broadcastDerbyState()
  -- Slots go out AFTER the state broadcast, so every client already holds the
  -- slot list it is about to be told to use. Join order (pid ascending) is
  -- deterministic and fair enough for a derby. Everyone is held whether or not
  -- a slot was placed for them — a driver with nowhere to line up still waits
  -- for GO rather than getting a free run at the rest of the field.
  local ordered = {}
  for id in pairs(derbyPlayers) do ordered[#ordered + 1] = id end
  table.sort(ordered)
  for slot, id in ipairs(ordered) do
    local placed = (slot <= #derby.startPositions) and slot or nil
    MP.TriggerClientEvent(id, 'RM_DerbyGridAssign', Util.JsonEncode({
      slot = placed,
      hold = true,
    }))
  end
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] Demo derby forming up: %d driver%s held for the start.',
    count, count == 1 and '' or 's'))
  print('[RaceManager] Derby formed up by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. count .. ' drivers, ' .. #derby.startPositions .. ' slots placed)')
end

function RM_onDerbyStart(pid)
  if not requireAuth(pid) then return end
  -- Form up first, so the field is standing still and held when the lights go
  -- out. Mirrors Start Countdown needing a generated grid.
  if derby.phase ~= 'forming' then
    if derby.phase ~= 'running' and derby.phase ~= 'countdown' then
      MP.SendChatMessage(pid, '[RaceManager] Press Form Up first — it places the '
        .. 'field and holds it for the countdown.')
    end
    return
  end
  derby.phase = 'countdown'
  derbyCountdownValue = DERBY_COUNTDOWN_FROM
  broadcastDerbyState()
  broadcastDerbyCountdown(derbyCountdownValue)
  MP.CreateEventTimer('RM_DerbyCountdownTick', 1000)
  print('[RaceManager] Derby countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_DerbyCountdownTick()
  if derby.phase ~= 'countdown' then
    MP.CancelEventTimer('RM_DerbyCountdownTick')
    -- Whatever ended the countdown (End Derby) must not leave the field held.
    broadcastDerbyCountdown(-1)
    return
  end
  derbyCountdownValue = derbyCountdownValue - 1
  if derbyCountdownValue > 0 then
    broadcastDerbyCountdown(derbyCountdownValue)
    return
  end
  -- GO! The same broadcast that clears the overlay releases every held car, so
  -- nobody can creep away early or be held a moment longer than their rivals.
  MP.CancelEventTimer('RM_DerbyCountdownTick')
  broadcastDerbyCountdown(0)
  derby.phase = 'running'
  derby.time  = 0
  MP.CreateEventTimer('RM_DerbyTick', DERBY_TICK_MS)
  broadcastDerbyState()
  local count = 0
  for _ in pairs(derbyPlayers) do count = count + 1 end
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] DEMO DERBY STARTED! %d drivers. Stay inside the arena and keep moving!', count))
  print('[RaceManager] Derby GO (' .. count .. ' drivers, '
    .. #derby.boundary .. ' boundary markers)')
end

-- End Derby (admin): if exactly one driver is still alive they take the win,
-- otherwise the derby closes with no winner.
function RM_onDerbyEnd(pid)
  if not requireAuth(pid) then return end
  -- Aborting before GO: no result to record, just put the field back. The
  -- countdown broadcast is what releases the held cars, so it has to go out
  -- even though nobody is racing yet -- otherwise everyone stays frozen.
  if derby.phase == 'forming' or derby.phase == 'countdown' then
    MP.CancelEventTimer('RM_DerbyCountdownTick')
    derbyCountdownValue = nil
    derby.phase  = 'idle'
    derby.winner = nil
    derby.time   = 0
    derbyPlayers = {}
    broadcastDerbyCountdown(-1)
    broadcastDerbyState()
    MP.SendChatMessage(-1, '[RaceManager] Demo derby start aborted.')
    print('[RaceManager] Derby start aborted by ' .. (MP.GetPlayerName(pid) or pid))
    return
  end
  if derby.phase ~= 'running' then
    -- Allow clearing a finished derby back to idle from the UI.
    if derby.phase == 'finished' then
      derby.phase = 'idle'
      derby.winner = nil
      derby.time = 0
      derbyPlayers = {}
      broadcastDerbyState()
      print('[RaceManager] Derby reset to idle by ' .. (MP.GetPlayerName(pid) or pid))
    end
    return
  end
  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = displayName(lastAlive)
  end
  finishDerby('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client self-reports: out-of-bounds timer expired.
function RM_onDerbyDisqualified(pid)
  derbyEliminate(pid, 'Disqualified')
end

-- Client self-reports: stopped-vehicle timer expired.
function RM_onDerbyDemolished(pid)
  derbyEliminate(pid, 'Demolished')
end

function RM_onDerbyRequestState(pid)
  broadcastDerbyState(pid)
end

-- Registered as an ADDITIONAL handler on onPlayerJoin/onPlayerDisconnect so
-- the circuit-racing handlers above stay untouched.
function RM_Derby_onPlayerJoin(pid)
  broadcastDerbyState(pid)  -- late joiners spectate the running derby
end

function RM_Derby_onPlayerDisconnect(pid)
  if derby.phase == 'running' and derbyPlayers[pid]
      and derbyPlayers[pid].status == 'alive' then
    derbyEliminate(pid, 'Disqualified')
  end
end

function RM_DerbyTick()
  if derby.phase ~= 'running' then
    MP.CancelEventTimer('RM_DerbyTick')
    return
  end
  derby.time = derby.time + DERBY_TICK_MS / 1000.0
  broadcastDerbyState()
end

-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Clock + lifecycle
-- ---------------------------------------------------------------------------
-- Race clock + the live-position broadcast loop. Clients feed telemetry in
-- continuously (RM_Progress) but never trigger a broadcast themselves; this is
-- the single throttled place where the running order is re-sorted, re-numbered
-- (buildDrivers -> assignPositions) and pushed to everyone.
function RM_Tick()
  if not sessionRunning() then return end
  -- One clock for both sessions. race.time is the session clock every finish
  -- time is stamped from; qualifying additionally runs its own wall clock,
  -- which is what closes the session when the admin set a time limit.
  race.time = race.time + TICK_MS / 1000.0
  if race.phase == 'qualifying' then
    if race.finalLap then
      -- The clock has already expired and the field is on its last lap. What is
      -- counting down now is the grace: a driver parked in the pits, or one who
      -- never left the grid, has no crossing to give, and the session must not
      -- wait on them forever.
      race.finalLapLeft = race.finalLapLeft - TICK_MS / 1000.0
      if race.finalLapLeft <= 0 then
        local stranded = {}
        for _, rec in pairs(players) do
          if onTrack(rec) then stranded[#stranded + 1] = rec end
        end
        -- Snapshot first: retireDriver sends a client event per driver, and
        -- building the list while that is going on is the shape of bug that
        -- reached only the last name in it.
        for _, rec in ipairs(stranded) do
          retireDriver(rec, 'Qualifying over — the session closed before you reached the line')
        end
        if #stranded > 0 then
          MP.SendChatMessage(-1, string.format(
            '[RaceManager] Final-lap grace expired: %d driver%s taken where they stood.',
            #stranded, #stranded == 1 and '' or 's'))
        end
        finishSession('the final-lap grace expired')
        return
      end
    else
      race.qualiTime = race.qualiTime + TICK_MS / 1000.0
      if race.qualiTimeLimit > 0 and race.qualiTime >= race.qualiTimeLimit then
        beginFinalLap()
        -- Not a return: the session is still running, and the broadcast below
        -- is what carries the final-lap flag to every client.
      end
    end
  end
  tickCounter = tickCounter + 1
  if tickCounter >= PUSH_EVERY_TICKS then
    tickCounter = 0
    broadcastState()
  end
end

function RM_onPlayerJoin(pid)
  -- Session ids are recycled. If a record already exists under this id but the
  -- connected player's name has changed, a DIFFERENT person now holds it, so the
  -- display identity must not carry over -- inheriting the previous player's
  -- alias would be impersonation by accident. Only the display fields are
  -- refreshed here; the record itself (and its lap data) is left alone, which is
  -- the pre-existing behaviour Generate Grid purges.
  pid = pidKey(pid)
  if not pid then return end
  local current = MP.GetPlayerName(pid)
  -- The registry is scoped to the connection, so a name that no longer matches
  -- retires the stored identity (and its entry decision) in one place. Do this
  -- BEFORE ensurePlayer, or the new record would inherit what is being dropped.
  identityFor(pid, current)
  local existing = players[pid]
  if existing then
    if current and current ~= existing.name then
      existing.name  = current
      existing.alias = nil
      existing.joined = false
      rememberIdentity(existing)
    end
  end
  local rec = ensurePlayer(pid)
  if not rec then return end
  -- Connecting is not entering: in the default opt-in mode a new arrival is a
  -- spectator until they press Join Race. In 'all' mode they are in the field
  -- straight away, which is what that mode means.
  if race.phase == 'qualifying' and isEntrant(rec) then rec.status = 'qualifying' end
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  pid = pidKey(pid)
  if not pid then return end
  -- Session IDs are reused, so a disconnecting admin must drop its auth flag;
  -- the next player to inherit this ID starts with no admin rights.
  local wasAdmin = authenticatedPlayers[pid] ~= nil
  authenticatedPlayers[pid] = nil
  local rec = players[pid]
  if not rec then
    -- Non-racer admin (e.g. a spectating host) left: still refresh adminPresent.
    if wasAdmin then broadcastState() end
    return
  end
  if onTrack(rec) or rec.status == 'gridded' then
    rec.status = 'dnf'
    rec.outReason = rec.outReason or 'DNF - Disconnected'
  elseif rec.status == 'waiting' then
    players[pid] = nil
  end
  -- If the last driver out on track just dropped, the session is over.
  if sessionRunning() then
    for _, r in pairs(players) do
      if onTrack(r) then
        broadcastState()
        return
      end
    end
    finishSession('no drivers left on track')
    return
  end
  broadcastState()
end

function onInit()
  MP.RegisterEvent('RM_Login',            'RM_onLogin')
  MP.RegisterEvent('RM_Logout',           'RM_onLogout')
  MP.RegisterEvent('RM_ChangePassword',   'RM_onChangePassword')
  MP.RegisterEvent('RM_StartQualifying',  'RM_onStartQualifying')
  MP.RegisterEvent('RM_GenerateGrid',     'RM_onGenerateGrid')
  MP.RegisterEvent('RM_SetTotalLaps',     'RM_onSetTotalLaps')
  MP.RegisterEvent('RM_SetAlias',         'RM_onSetAlias')
  -- Race entry (opt-in) + starting grid
  MP.RegisterEvent('RM_JoinRace',           'RM_onJoinRace')
  MP.RegisterEvent('RM_SetEntryMode',       'RM_onSetEntryMode')
  MP.RegisterEvent('RM_SetGridMode',        'RM_onSetGridMode')
  MP.RegisterEvent('RM_SetDriverGrid',      'RM_onSetDriverGrid')
  MP.RegisterEvent('RM_StartPositionCount', 'RM_onStartPositionCount')
  -- Qualifying session rules
  MP.RegisterEvent('RM_SetGhostQuali',    'RM_onSetGhostQuali')
  MP.RegisterEvent('RM_SetQualiLimits',   'RM_onSetQualiLimits')
  -- Module 1: vehicle reset ruleset + forced spectator reports
  MP.RegisterEvent('RM_SetMaxResets',     'RM_onSetMaxResets')
  MP.RegisterEvent('RM_SetResetMode',     'RM_onSetResetMode')
  MP.RegisterEvent('RM_VehicleReset',     'RM_onVehicleReset')
  MP.RegisterEvent('RM_ResetDenied',      'RM_onResetDenied')
  -- Module 2: rallycross joker lap
  MP.RegisterEvent('RM_SetJokerEnabled',  'RM_onSetJokerEnabled')
  MP.RegisterEvent('RM_JokerLap',         'RM_onJokerLap')
  -- Module 4: garage list (vehicle & setup locking)
  MP.RegisterEvent('RM_WhitelistVehicle', 'RM_onWhitelistVehicle')
  MP.RegisterEvent('RM_ClearGarage',      'RM_onClearGarage')
  MP.RegisterEvent('RM_RemoveGarageEntry','RM_onRemoveGarageEntry')
  MP.RegisterEvent('RM_SetGarageEnforce', 'RM_onSetGarageEnforce')
  MP.RegisterEvent('RM_VehicleConfig',    'RM_onVehicleConfig')
  MP.RegisterEvent('onVehicleSpawn',      'RM_onVehicleSpawn')
  MP.RegisterEvent('onVehicleEdited',     'RM_onVehicleEdited')
  MP.RegisterEvent('RM_StartCountdown',   'RM_onStartCountdown')
  MP.RegisterEvent('RM_EndRace',          'RM_onEndRace')
  MP.RegisterEvent('RM_ResetLeaderboard', 'RM_onResetLeaderboard')
  MP.RegisterEvent('RM_ClearResults',     'RM_onClearResults')
  MP.RegisterEvent('RM_Lap',              'RM_onLap')
  MP.RegisterEvent('RM_Progress',         'RM_onProgress')  -- live position telemetry
  MP.RegisterEvent('RM_RequestState',     'RM_onRequestState')
  MP.RegisterEvent('RM_RequestLayouts',   'RM_onRequestLayouts')
  MP.RegisterEvent('RM_SaveLayout',       'RM_onSaveLayout')
  MP.RegisterEvent('RM_LoadLayout',       'RM_onLoadLayout')
  MP.RegisterEvent('RM_ClearTrackState',  'RM_onClearTrackState')
  -- Demo Derby module (isolated event namespace; see the DEMO DERBY section).
  MP.RegisterEvent('RM_DerbySetConfig',     'RM_onDerbySetConfig')
  MP.RegisterEvent('RM_DerbyAddMarker',     'RM_onDerbyAddMarker')
  MP.RegisterEvent('RM_DerbyClearBoundary', 'RM_onDerbyClearBoundary')
  MP.RegisterEvent('RM_DerbyAddStart',      'RM_onDerbyAddStart')
  MP.RegisterEvent('RM_DerbyClearStarts',   'RM_onDerbyClearStarts')
  MP.RegisterEvent('RM_DerbyVehicleReset',  'RM_onDerbyVehicleReset')
  MP.RegisterEvent('RM_DerbyResetDenied',   'RM_onDerbyResetDenied')
  MP.RegisterEvent('RM_DerbyStart',         'RM_onDerbyStart')
  MP.RegisterEvent('RM_DerbyEnd',           'RM_onDerbyEnd')
  MP.RegisterEvent('RM_DerbyDisqualified',  'RM_onDerbyDisqualified')
  MP.RegisterEvent('RM_DerbyDemolished',    'RM_onDerbyDemolished')
  MP.RegisterEvent('RM_DerbyRequestState',  'RM_onDerbyRequestState')
  MP.RegisterEvent('RM_DerbySetEntryMode',  'RM_onDerbySetEntryMode')
  MP.RegisterEvent('RM_DerbyFormUp',        'RM_onDerbyFormUp')
  -- Derby arena layouts (save/load, mirroring the track layout workflow)
  MP.RegisterEvent('RM_DerbyRequestLayouts','RM_onDerbyRequestLayouts')
  MP.RegisterEvent('RM_DerbySaveLayout',    'RM_onDerbySaveLayout')
  MP.RegisterEvent('RM_DerbyLoadLayout',    'RM_onDerbyLoadLayout')
  MP.RegisterEvent('RM_DerbyDeleteLayout',  'RM_onDerbyDeleteLayout')
  MP.RegisterEvent('RM_DerbyTick',          'RM_DerbyTick')
  -- Timer events only fire if they are registered like any other event. Missing
  -- this one left the derby countdown frozen on 3 forever: the timer was
  -- created and ticked, and nothing was listening.
  MP.RegisterEvent('RM_DerbyCountdownTick', 'RM_DerbyCountdownTick')
  MP.RegisterEvent('onPlayerJoin',          'RM_Derby_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',    'RM_Derby_onPlayerDisconnect')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', TICK_MS)
  -- Boot from a clean slate: any client still connected across a plugin
  -- reload drops its stale gates, then the layout cache is re-warmed from disk.
  clearTrackState('server startup')
  getLayouts()       -- warm the layout cache so saved tracks survive the restart visibly
  getGarage()        -- and the approved vehicle list (Module 4)
  getDerbyLayouts()  -- and the saved derby arenas
  print('[RaceManager] Server plugin loaded (build ' .. RM_BUILD
    .. ', circuit edition, map: ' .. getCurrentMap() .. ')')
end
