-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative session state machine:
--
--   waiting -> qualifying -> grid -> countdown -> racing -> finished
--
-- Clients time their own laps (the server has no physics) and report each one;
-- everything that must be fair across drivers (finish order, laps led) is
-- decided by arrival order and the server clock.
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- SERVER CONFIGURATION
-- ---------------------------------------------------------------------------
-- Every number an admin might change, seeded here and overridden from
-- config.json beside layouts.json at boot (written out on first run). SEEDED,
-- NOT LIVE: the panel changes race.totalLaps, never this. saveConfigToDisk is
-- declared here because the password handlers sit far above the writer.
--
-- Make this plugin's folder importable: BeamMP does it, the test harness (which
-- dofile()s this from the repo root) does not. Derived from this file's path.
do
  -- Long-bracket string so the Windows separator needs no escaping.
  local src = debug.getinfo(1, 'S').source:sub(2):gsub([[\]], '/')
  package.path = (src:match('^(.*)/[^/]+$') or '.') .. '/?.lua;' .. package.path
end

local saveConfigToDisk

local CFG = {
  -- The admin password, persisted so a change survives a restart. The FULL
  -- tier: an upgraded server's adminPassword keeps every right it had.
  adminPassword = 'phoenix',

  -- The race director's password: everything except changing passwords,
  -- clearing results and deleting a layout (see requireAdmin). EMPTY MEANS OFF,
  -- as shipped, and an empty password never matches.
  moderatorPassword = '',

  -- What a race starts as.
  totalLaps     = 5,
  raceTimeLimit = 0,         -- seconds, 0 = run to a lap count instead
  maxResets     = -1,        -- -1 unlimited, 0 none, N per driver per session
  resetMode     = 'inplace', -- 'inplace' | 'checkpoint'
  nametags      = false,
  countdownFrom = 3,         -- 3, 2, 1, GO!
  endDelay      = 5,         -- seconds the results are held after the last car home

  -- THE PACE LAP: released under yellow, green as the leader returns to the line
  -- (paceLapArmed, RM_onStartRace).
  paceLap       = false,
  -- The fallback green point (meters before the line, as the leader ARRIVES) on
  -- a track the server holds no route for.
  paceGreenAt   = 10.0,
  -- With a route: GET READY within paceReadyAt of the line on the final sector,
  -- the green at a random point between paceGreenNear and paceGreenFar, drawn
  -- per pace lap and restart so the field cannot learn it.
  paceReadyAt   = 50.0,
  paceGreenNear = 5.0,
  paceGreenFar  = 15.0,
  -- How far the leader must first get AWAY from the line: the field starts the
  -- pace lap standing on it.
  paceArmAt     = 50.0,

  -- THE FREE PASS ("lucky dog"): the highest-placed lapped car gets its lap back
  -- before the restart. Off by default, like every scoring rule.
  luckyDog      = false,
  -- Laps a heat runs; 0 is the race's distance.
  heatLaps      = 0,

  -- THE BLUE FLAG: shown within blueFlagWithin seconds, cleared past
  -- blueFlagClear. Two numbers, so a car hovering at one threshold does not make
  -- the flag strobe.
  blueFlagWithin = 2.0,
  blueFlagClear  = 4.0,

  -- Qualifying, as a session starts.
  qualiLapLimit  = 0,        -- timed laps per driver, 0 = unlimited
  qualiTimeLimit = 0,        -- seconds, 0 = no limit
  finalLapGrace  = 180,      -- seconds a final lap may take before it is closed

  -- Reset ghosting.
  ghostOnReset     = true,
  ghostMinSeconds  = 5.0,
  ghostMaxSeconds  = 15.0,

  -- The standing-start hold.
  holdTolerance    = 0.5,    -- meters a held car may drift off its slot
  holdCorrectEvery = 0.5,    -- seconds between corrections for one driver

  -- ADVANCED: plugin behaviour, with limits that keep a typo from becoming a hang.
  tickMs          = 100,     -- server clock resolution
  pushEveryTicks  = 3,       -- broadcasts are one in this many ticks
  maxTotalLaps    = 500,
  maxResetLimit   = 99,
  maxHeats        = 12,      -- ceiling on the heat count, so a typo is not a hang
  maxQualiLaps    = 99,
  maxQualiTime    = 7200,    -- seconds (2 h)
  maxRaceTime     = 21600,   -- seconds (6 h), so an endurance race is expressible
  unlimitedResets = -1,      -- the sentinel, not a preference: do not change

  -- Forming a grid, a derby form-up and a drag pass call the drivers, and each
  -- presses Ready to be placed. false places everyone at once (pre-0.17.2).
  readyCheck      = true,

  -- Map switching and voting. See maps.lua.
  mapRestart      = 'auto',  -- auto | watch | relaunch | exit | manual
  mapRestartGrace = 90,      -- seconds to wait for an outside restart (watch)
  mapVoting       = true,    -- drivers may call a map vote; admins always can
  mapVotePercent  = 60,      -- share of everyone connected who must vote yes
}
-- Forward declarations: the layout store's validators are needed by the grid
-- hold code above them.
local sanitizeCheckpoints
local sanitizeBranches

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  phase        = 'waiting',  -- waiting | grid | countdown | qualifying | racing | finished
  -- Which session the ONE lifecycle is running: only the lap target and how a
  -- lap is scored differ.
  sessionKind  = 'race',     -- race | quali
  -- Display names on BeamMP nametags too. Off by default (RM_onSetNametags).
  nametags     = false,
  time         = 0.0,        -- seconds since GO (advanced by RM_Tick while a session runs)
  totalLaps    = CFG.totalLaps,
  maxResets    = CFG.unlimitedResets,  -- vehicle resets allowed per driver per session
  resetMode    = 'inplace',  -- what a legal reset does: 'inplace' | 'checkpoint'
  jokerEnabled = false,      -- rallycross joker lap required exactly once per race
  -- ---------------------------------------------------------------------
  -- THE PACE LAP
  -- ---------------------------------------------------------------------
  -- `paceLap` is the RULE (locked once the field is released); `pacing` is the
  -- CONDITION, a field over an ordinary 'racing' phase, read in the four places
  -- that care. Mechanically a pace lap is an OUT LAP (outLapOwed): per driver,
  -- so the green falls once for everyone and each driver's own crossing starts
  -- their race.
  paceLap      = CFG.paceLap,
  pacing       = false,
  -- Has the leader got away from the line yet (CFG.paceArmAt)?
  paceArmed    = false,
  -- Meters before the line the green falls at, drawn per pace lap and restart
  -- (race.drawGreenZone). Never broadcast: a readable spot is a learnable one.
  greenZone    = nil,
  -- GET READY has been called for this pace lap or restart.
  greenReady   = false,
  -- ---------------------------------------------------------------------
  -- THE CAUTION
  -- ---------------------------------------------------------------------
  -- A full-course yellow that FREEZES THE RUNNING ORDER: the one half of a real
  -- caution a server without physics can enforce (a scoring rule, not a movement
  -- one). IT IS RACED BACK TO: calling it sets `cautionPending`; when the LEADER
  -- takes the line it goes official on `cautionLap`, and every driver locks their
  -- place as they complete that lap. A snapshot at the button would hand a place
  -- to whoever was mid-overtake.
  caution      = false,
  -- Called, and waiting on the leader; the board is still live.
  cautionPending = false,
  -- The leader's lap at the yellow, and laps run under it (caution laps COUNT).
  cautionLap   = nil,
  cautionLaps  = 0,
  -- Cautions this race has seen, for the results file.
  cautionCount = 0,
  -- Order cars have taken the line since the caution went official: the frozen
  -- order within a lap.
  cautionSeq   = 0,
  -- The free pass: the admin's switch, and the driver awarded it this caution
  -- (ONE per caution).
  luckyDog     = CFG.luckyDog,
  cautionLucky = nil,
  -- A restart called and not yet taken: the LEADER decides when, as they come
  -- back to the line. Cancellable until the green falls.
  restartPending = false,
  -- ---------------------------------------------------------------------
  -- THE HEAT PROGRAM
  -- ---------------------------------------------------------------------
  -- Several short heats then a feature; a heat IS an ordinary race run by a
  -- subset of the field.
  --   heatCount     heats in the night; 0 = no program and every rule inert
  --   heatTransfer  drivers who transfer from each heat, ahead of the rest
  --   heatCurrent   heat being set up or run; 0 = the feature (or a race)
  --   heatsDrawn    whether the field has been split
  --   heatLaps      laps a heat runs; 0 = the race's distance
  --   heatDraw      what the serpentine draw is seeded on: 'quali' (default,
  --                 spreads the quick drivers), 'random', or 'points'
  heatCount    = 0,
  heatTransfer = 0,
  heatCurrent  = 0,
  heatsDrawn   = false,
  heatLaps     = CFG.heatLaps,
  heatDraw     = 'quali',
  -- race.time at the green. The session clock is never wound back (ghost end
  -- times are on it); the pace lap is subtracted where it must not count.
  greenAt      = 0.0,
  -- Joker gates the loaded track has: the rule cannot be armed without them.
  jokerGates   = 0,
  -- THE FLAG: green, yellow or red. A CONDITION, NOT A PHASE: red means stop and
  -- the session goes yellow and back to green with nothing ended. Advisory: it
  -- is shown, announced and recorded, and polices nothing.
  flag         = 'green',
  -- Race entry: 'all' (default) grids everyone connected, 'join' only those who
  -- pressed Join Race. 'all' fails safe: a wrong 'join' grids nobody, a wrong
  -- 'all' is undone with Leave.
  -- How the grid is filled: quali, reverse, random, custom (RM_SetDriverGrid),
  -- heats, points, pointsrev.
  gridMode     = 'quali',
  startSlots   = 0,          -- start positions the loaded track layout has
  -- Ready check: forming the grid gives each driver a slot, placed when they
  -- press Ready. gridSize is the last slot handed out (a late arrival goes last).
  readyCheck   = CFG.readyCheck,
  gridSize     = 0,
  -- A point-to-point sprint stage: driven once, the last gate a finish.
  pointToPoint = false,
  -- A point-to-point layout filed as a drag strip. Only the Layouts menu reads
  -- it: any P2P with lanes still runs a ladder. Never true on a circuit.
  dragStrip    = false,
  -- BRANCH GATES: another way through an existing slot, so cpCleared means the
  -- same whichever gates were taken. Held only to validate, persist and send:
  --   { { slot = 1, x, y, z, hx, hy, width?, height?, oneWay? }, ... }
  branches     = {},
  -- The loaded layout itself, so a late joiner is sent it too: a track is
  -- state, not an announcement.
  layout       = nil,
  -- Slots in a lap (0 with no layout), to clamp reported progress.
  slotCount    = 0,
  -- Does this track grid away from the S/F line? Then the run to the first
  -- crossing is an untimed part lap (outLapOwed).
  gridOffLine  = false,
  -- THE HOLD AT THE FLAG: `endsAt` is the race.time the session closes at (nil
  -- until armed), so ghosts and finished cars do not all lift on the tick the
  -- last car crosses. On the table for the locals ceiling. endDelay 0 closes at
  -- once.
  endsAt       = nil,
  endReason    = nil,
  endDelay     = 5,
  -- Where the start positions are, { x, y, z, hx, hy } per slot: reported by a
  -- client or set from a loaded layout. Policing the hold needs coordinates.
  startPositions = {},
  -- Qualifying session rules.
  ghostQuali     = false,    -- rivals are ghosts during qualifying
  -- qualiLapLimit counts TIMED laps: the out lap is extra.
  qualiLapLimit  = 0,        -- timed laps allowed per driver (0 = unlimited)
  qualiTimeLimit = 0,        -- seconds the session runs for (0 = unlimited)
  qualiTime      = 0.0,      -- seconds elapsed in the current quali session
  -- Did the qualifying behind the board give an out lap away? A RECORD for the
  -- results file, written after the live rule has moved on.
  qualiOutLapRun = false,
  -- The same record for a race (see race.gridOffLine).
  raceOutLapRun  = false,
  -- ...and whether it was a PACE LAP: a head-on out lap comes OUT of the
  -- distance, a formation lap goes ON TOP, and the Laps column must say which.
  racePaceLapRun = false,
  -- TIMED session expiry: the clock ends for everybody at once while they are
  -- spread round the circuit, so it changes what a crossing MEANS instead of
  -- ending the session: the next S/F crossing is terminal (finalLap), reusing
  -- the lap-limited path's removal.
  -- Fastest lap so far and its holder, kept incrementally (laps are rare,
  -- broadcasts three a second).
  bestLapTime    = nil,
  bestLapPid     = nil,
  finalLap       = false,
  finalLapLeft   = 0,        -- grace left before stragglers are taken where they stand

  -- ---------------------------------------------------------------------
  -- TIMED RACES: "10 minutes + 1 lap"
  -- ---------------------------------------------------------------------
  -- The clock does not end the race: it ends one lap after the LEADER next
  -- takes the line.
  --   raceExpired  the clock is out; the leader has to reach the line first
  --   lastLapNum   the leader crossed; completing THIS lap ends a driver's race,
  --                so a car just behind still gets a full lap
  --   finalLap     the leader finished; the NEXT crossing is terminal for all
  -- raceMode names which limits are live (endurance has both):
  --   'laps'       a fixed distance; raceTimeLimit is 0
  --   'timed'      a clock plus one lap; totalLaps is inert
  --   'endurance'  whichever comes first; reaching the distance ends the race
  --                for everybody (see RM_onLap)
  raceMode       = 'laps',
  raceTimeLimit  = CFG.raceTimeLimit,
  raceExpired    = false,    -- clock out, waiting on the leader
  raceExpiredAt  = nil,      -- race.time it expired, for the stuck-field valve
  lastLapNum     = nil,      -- the lap number that is the final one
}
local players = {}          -- [playerID] = per-player record

-- Release a frozen caution order. Declared beside `players`: finishSession,
-- far above the caution code, calls it, and a later local would be a nil global.
local function thawOrder()
  for _, rec in pairs(players) do rec.cautionPos, rec.cautionDown = nil, nil end
end
-- Authoritative reset ghosts, [playerID] = { startedAt, duration } on
-- race.time, so a driver joining mid-ghost is told. Per player: independent.
local ghosts = {}
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'
local lapFirsts = {}        -- [lapNumber] = pid of the first driver to complete that lap

-- Empty a table WITHOUT replacing it, so a reference a module took at init
-- stays the live table.
local function wipe(t)
  for k in pairs(t) do t[k] = nil end
  return t
end
-- Is this session driven behind a pace car? Qualifying has no field to form up
-- and a sprint stage no lap to form up on. Asked, not stored, so it stays true
-- of the session in front of it.
local function paceLapArmed()
  if race.pointToPoint then return false end
  return race.paceLap == true and race.sessionKind == 'race'
end

-- Laps this race runs, before the pace lap: a heat's own distance when one is
-- set (heatLaps 0 is the race's), else race.totalLaps.
local function raceDistance()
  if race.heatCount > 0 and race.heatCurrent > 0 and race.heatLaps > 0
      and race.sessionKind == 'race' then
    return race.heatLaps
  end
  return race.totalLaps
end

-- How long the RACE has run, which a timed race is measured on: zero during
-- the pace lap, then from the green. race.time itself is never wound back.
local function raceElapsed()
  if race.pacing then return 0.0 end
  return race.time - race.greenAt
end

-- Does this session open with an OUT LAP (untimed, unscored, outside the
-- allowance)? Qualifying from a standing grid, a race gridded away from the
-- line (race.gridOffLine, from the layout), and a pace lap. Never a sprint.
local function outLapOwed()
  if race.pointToPoint then return false end
  -- A pace lap IS an out lap: driven, not scored, ending at the line per driver.
  return race.sessionKind == 'quali' or race.gridOffLine == true or paceLapArmed()
end



-- ---------------------------------------------------------------------------
-- Admin authentication
-- ---------------------------------------------------------------------------
-- Guest ids rotate, so admin rights are a shared password. TWO TIERS:
--   admin      everything, including the three with no undo (changing either
--              password, clearing results, deleting a layout)
--   moderator  everything else: sessions, grids, flags, settings, the editor,
--              the cup, the derby, the drag ladder
-- authenticatedPlayers holds the ROLE. One `auth` table for the locals ceiling.
local auth = {
  ADMIN = 'admin',
  MOD   = 'moderator',
  -- Re-seeded from config.json by applyConfigToRace.
  adminPw = CFG.adminPassword,
  modPw   = CFG.moderatorPassword,
}
local authenticatedPlayers = {}   -- [playerID] = 'admin' | 'moderator'

-- Either tier: what the admin handlers ask. (A role string is truthy, not true.)
local function isAuthenticated(pid)
  return authenticatedPlayers[pid] ~= nil
end

-- The full tier, for the three commands with no undo.
function auth.isFull(pid)
  return authenticatedPlayers[pid] == auth.ADMIN
end

-- Which tier a password is worth, or nil. Admin is tested first (equal strings
-- grant the higher tier); an empty moderator password never matches.
function auth.roleOf(pass)
  if type(pass) ~= 'string' or pass == '' then return nil end
  if pass == auth.adminPw then return auth.ADMIN end
  if auth.modPw ~= '' and pass == auth.modPw then return auth.MOD end
  return nil
end

-- Guard on every admin handler. The refusal is ANSWERED (RM_LoginResult
-- lapsed): session ids are reused, so a reconnect drops auth here while the
-- client's cached flag shows dead admin controls.
local function requireAuth(pid)
  if authenticatedPlayers[pid] then return true end
  print('[RaceManager] Ignored admin command from unauthenticated player ' .. tostring(pid))
  MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({
    success = false, lapsed = true,
  }))
  return false
end

-- The full-tier guard. Answered on RM_Denied, NOT RM_LoginResult, which would
-- log a moderator out of a session they are legitimately in.
function auth.requireFull(pid)
  if not requireAuth(pid) then return false end
  if auth.isFull(pid) then return true end
  print('[RaceManager] Refused an admin-only command from moderator '
    .. (MP.GetPlayerName(pid) or tostring(pid)))
  MP.TriggerClientEvent(pid, 'RM_Denied', Util.JsonEncode({
    reason = 'That needs the admin password: a moderator cannot change '
      .. 'passwords, clear the results or lap records, or delete a layout.',
  }))
  return false
end

local function newRecord(pid)
  return {
    id         = pid,
    name       = MP.GetPlayerName(pid) or ('Player ' .. pid),
    -- Admin-assigned display name; nil shows the real one.
    alias      = nil,
    -- waiting | qualifying | gridded | racing | finished | dsq | dnf
    status     = 'waiting',
    -- Self-declared spectator: the only way out of the field. Mirrored into the
    -- identity registry, so it survives the online purge.
    spectating = false,
    gridPos    = nil,        -- locked-in starting position (Generate Grid)
    customGrid = nil,        -- slot the admin pinned this driver to (custom mode)
    qualiBest  = nil,        -- best qualifying lap (seconds)
    qualiLaps  = 0,          -- timed qualifying laps completed this session
    -- Still owes the out lap: the next crossing starts timing. Per driver: the
    -- field is spread round the circuit.
    outLap     = false,
    raceBest   = nil,        -- best race lap (seconds)
    currentLap = 0,          -- lap the driver is currently on (1-based once racing)
    lapsLed    = 0,          -- laps this driver crossed the line first on
    finishTime = nil,        -- server race clock at final-lap completion
    resets     = 0,          -- vehicle resets consumed this session
    resetsBlocked = 0,       -- resets refused after the allowance ran out
    ghosts     = 0,          -- reset ghosts armed this session (audit trail)
    pitStops   = 0,          -- pit stalls used this session
    holdCorrections = 0,     -- times this car was pulled back onto its grid slot
    holdCorrectedAt = nil,   -- race.time of the last correction (rate limiting)
    jokerTaken = 0,          -- completed runs of the joker route this race
    jokerLap   = nil,        -- lap the joker route was taken on
    -- Where this driver locked under the caution, stamped at their own crossing:
    --   cautionDown  laps down on the leader (0 = lead lap), compared FIRST
    --   cautionPos   order back to the line within that
    -- nil while racing back, or for a later joiner (sorted live behind).
    cautionPos = nil,
    cautionDown = nil,
    -- The blue flag, recomputed per broadcast (nil for all under a caution):
    --   blue     a car a lap or more up is close behind: let them by
    --   lapping  the car close ahead is a lap or more down
    blue       = nil,
    lapping    = nil,
    -- Last broadcast's `blue`, for the hysteresis. Not sent.
    blueWas    = nil,
    -- The heat program per driver, mirrored into the identity registry so a
    -- dropout between heats keeps a transfer earned.
    heat        = nil,       -- which heat this driver was drawn into
    heatPos     = nil,       -- where they finished it
    transferred = nil,       -- true once they took a transfer spot out of it
    -- Joined mid-session: not a participant, ghosted until the next grid.
    bystander  = nil,
    outReason  = nil,        -- why this driver is dnf/dsq (results + UI text)
    -- Where a retirement classifies, and where it was running when it stopped
    -- (the live order drops a stopped car to the bottom at once).
    dnfPos     = nil,      -- where a retirement CLASSIFIES: behind the field
    heldPos    = nil,      -- the place it was running in when it stopped
    -- Live position tracking (see the "Running order" section below).
    position   = nil,        -- current place in the running order (1 = leader)
    cpCleared  = 0,          -- checkpoints passed on the current lap
    distNext   = nil,        -- meters from the car to the next checkpoint center
    -- Split timing: [lap][checkpoint] = race.time reached, and the last stamp.
    splits     = nil,        -- built lazily by progress.record
    splitLap   = nil,
    splitCp    = nil,
    -- Gap to the leader and interval to the car ahead, at THIS driver's last
    -- checkpoint (assignPositions). nil when there is nothing honest to say.
    gap        = nil,
    intv       = nil,
    -- Module 4: the last declared configuration and the ruling, recorded even
    -- when not enforcing. carOk is THREE-VALUED: true approved, false not on
    -- the list, nil nothing to say (never an offender).
    carOk       = nil,
    carSig      = nil,   -- model + parts + tuning
    carPartsSig = nil,   -- model + parts, the half 'parts' mode matches on
    carLabel    = nil,   -- what to call it in the audit
    carGame     = nil,   -- BeamNG build, for the version-skew message
    -- Class, from the Garage List entry the car matches; nil is unclassified.
    class       = nil,
    -- Place within the class, nil when no class is in use.
    classPos    = nil,
  }
end

-- ---------------------------------------------------------------------------
-- Live progress: the checkpoint telemetry, and the splits built out of it
-- ---------------------------------------------------------------------------
-- One table for both, for the locals ceiling.
local progress = {}

-- Wipe a driver's telemetry when their lap state restarts. NOT the splits: this
-- runs every lap, and the splits belong to the session (cleared at grid and GO).
function progress.clear(rec)
  rec.cpCleared = 0
  rec.distNext  = nil
end

-- ---------------------------------------------------------------------------
-- Split timing: when each driver reached each checkpoint
-- ---------------------------------------------------------------------------
-- A gap to the leader is a subtraction of race.time stamps at the same
-- checkpoint: one server clock, nothing estimated, and immune to branch gates.
-- Nested per lap (slotCount can be 0 for an unsaved route). BACKFILLED ON A
-- JUMP: the leader's stamp at the follower's checkpoint is looked up, so one
-- hole blanks the whole gap column; a driver reporting CP 4 after CP 2 passed 3
-- no later than now.
function progress.record(rec, lap, cp)
  if not rec.splits then rec.splits = {} end
  local onLap = rec.splits[lap]
  if not onLap then onLap = {}; rec.splits[lap] = onLap end
  onLap[cp] = race.time
  -- Kept explicitly: a finisher's currentLap stays put while their last split
  -- is the flag.
  rec.splitLap, rec.splitCp = lap, cp
  -- Back to the start of this lap only.
  for k = cp - 1, 0, -1 do
    if onLap[k] then break end
    onLap[k] = race.time
  end
end

-- ---------------------------------------------------------------------------
-- Display aliases (presentation only -- NEVER a key)
-- ---------------------------------------------------------------------------
-- No stable identity exists (session ids are recycled, guest names regenerate),
-- so an alias lives ON THE PLAYER RECORD, never in a side table keyed by id.
-- Never a lookup key: only displayName reads it.
local MIN_ALIAS_LEN = 3
local MAX_ALIAS_LEN = 20    -- results file pads the Driver column to 22
-- Names nobody may take (posing as staff). Case-insensitive.
local RESERVED_ALIASES = {
  ['admin'] = true, ['server'] = true, ['host'] = true, ['console'] = true,
  ['system'] = true, ['racemanager'] = true, ['race manager'] = true,
}

-- Alias for any record with a player id. The derby's own records resolve
-- through the racing record, so a mid-derby rename shows at once.
local function aliasOf(rec)
  if not rec then return nil end
  if rec.alias then return rec.alias end
  local owner = rec.id and players[rec.id]
  return owner and owner.alias or nil
end

-- Alias if set, else the real name; never nil or empty.
local function displayName(rec)
  if not rec then return '?' end
  return aliasOf(rec) or rec.name
end

-- Cleaned alias, or nil and a reason. ASCII only: the results file pads columns
-- with %-22s, which counts bytes, so a multi-byte character misaligns rows.
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

-- Taken as somebody's alias OR real name?
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
-- `players` is rebuilt per session; the display name, the sit-out decision,
-- heat and class live here so they survive it. Keyed by player id, handed back
-- only when the guest NAME still matches (ids are recycled), so a stranger
-- inheriting the id starts clean.
local identities = {}   -- [pid] = { name = <guest name>, alias = ..., spectating = bool }

-- Every player id goes through here: MP.GetPlayers() keys may not compare equal
-- to ours, which once purged a whole opted-in grid as "not online".
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

-- The stored identity for this connection, cleared when the name no longer
-- matches (somebody else holds the id).
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

-- Write the durable half of a record back, from everywhere it can change.
local function rememberIdentity(rec)
  if not rec or not rec.id then return end
  identities[rec.id] = {
    name   = rec.name,
    alias  = rec.alias,
    spectating = rec.spectating == true,
    -- Heat and class ride here too: Generate Grid purges offline records, and a
    -- driver reconnecting between sessions must keep their heat, transfer and
    -- class.
    heat        = rec.heat,
    heatPos     = rec.heatPos,
    class       = rec.class,
    transferred = rec.transferred,
    -- The car's name, for lap records: a client only declares it on a change.
    car         = rec.carLabel,
  }
end

-- Put the whole field back in (Reset Session): clears every sit-out, on both the
-- record and the registry. Display names stay.
local function clearEntries()
  for _, ident in pairs(identities) do
    ident.spectating = false
  end
  for _, rec in pairs(players) do
    rec.spectating = false
  end
end

local function ensurePlayer(pid)
  pid = pidKey(pid)
  if not pid then return nil end
  if not players[pid] then
    local rec = newRecord(pid)
    -- A known connection inherits its identity: the record is disposable.
    local ident = identityFor(pid, rec.name)
    if ident then
      rec.alias  = ident.alias
      rec.spectating = ident.spectating == true
      rec.heat        = ident.heat
      rec.heatPos     = ident.heatPos
      rec.class       = ident.class
      rec.transferred = ident.transferred
      rec.carLabel    = ident.car
    end
    players[pid] = rec
    rememberIdentity(rec)
  end
  return players[pid]
end

-- Forward declaration: entry changes refresh the derby panel's field size.
local derbyEntryListChanged
-- "Is a derby running?", for the racing side, without reaching into derby
-- state. On `race`, like the hooks below (the locals ceiling).
race.derbyUnderWay = function () return false end
-- The drag ladder's hooks on `race`, all inert by default, so a drag.lua that
-- fails to load costs the drag tab only:
--   dragUnderWay     a pass is on the strip (no racing grid onto it)
--   dragEntryChanged the entry list moved
--   dragWarm         boot-time load of a half-run ladder
race.dragUnderWay    = function () return false end
race.dragEntryChanged = function () end
race.dragWarm        = function () end
race.dragSetCupHooks = function () end

-- Forward declarations for the roster and cup at the bottom of the file (they
-- need the JSON codec and layout directory defined below):
--   rosterRemember / rosterUnbind / rosterEntryFor   bind, unbind, look up
-- There is NO automatic recognition: guest names prove nothing, so binding a
-- connection to a roster entry is an admin's decision only.
--   cupOnSessionComplete / cupOnDragComplete / cupOnDerbyComplete   score a
--     finished session; each hands over a classification, never module state
--   cupResultsLines   the banked round as results-file lines (nil with no cup)
local rosterRemember, rosterUnbind, rosterEntryFor
local rosterBindTo, rosterList, rosterForget
--   cupSeasonPoints(rec)  championship total, for the heat draw
local cupOnSessionComplete, cupOnDerbyComplete, cupResultsLines, cupSeasonPoints
local cupOnDragComplete
-- Boot-time cache warm. Both modules live in do-blocks, so only these names
-- cross out.
local rosterWarm, cupWarm

-- ---------------------------------------------------------------------------
-- Race entry list
-- ---------------------------------------------------------------------------
-- EVERYONE RACES UNLESS THEY SPECTATE. A heat is an ordinary race run by a
-- subset of the field, and this is the whole of what makes that true: during a
-- heat (heatCount > 0, heatCurrent > 0) only that heat's drivers are entrants.
-- QUALIFYING IS NEVER SPLIT: the draw is made from its times.
local function isEntrant(rec)
  if not rec then return false end
  if rec.spectating then return false end
  if race.heatCount > 0 and race.heatCurrent > 0 and race.sessionKind == 'race' then
    return rec.heat == race.heatCurrent
  end
  return true
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
-- Classification bucket for the live table and results: finishers, running,
-- excluded (joker), DNF.
local function classRank(rec)
  if rec.status == 'dnf' then return 3 end
  if rec.status == 'dsq' then return 2 end
  if rec.finishTime then return 0 end
  return 1
end

-- The live running order between two circulating drivers:
--   1. Laps completed (the SERVER's counter, so no client can invent a lap)
--   2. Checkpoints cleared on the current lap
--   3. Distance to the next checkpoint (client-measured), shorter ahead
-- Laps down on the caution lap, or nil before the caution is official: the stamp
-- once locked, else the same arithmetic live (they agree, so the board does not
-- jump as cars lock). Clamped at zero.
local function cautionDownOf(rec)
  if rec.cautionDown then return rec.cautionDown end
  if not race.cautionLap then return nil end
  local d = race.cautionLap - (rec.currentLap or 0)
  if d < 0 then d = 0 end
  return d
end

local function raceOrderLess(a, b)
  local ra, rb = classRank(a), classRank(b)
  if ra ~= rb then return ra < rb end
  -- Finishers (and drivers excluded after finishing) are ordered by the flag.
  if (ra == 0 or ra == 2) and a.finishTime and b.finishTime and a.finishTime ~= b.finishTime then
    return a.finishTime < b.finishTime
  end
  -- THE CAUTION ORDER, first for cars still circulating, so closing up under
  -- yellow (as told) gains no places:
  --   1. LAPS DOWN at the caution lap: lapped cars behind the whole lead lap.
  --   2. Order back to the line within that; a car not back yet sorts behind,
  --      ranked live against the others still racing back.
  -- After the finisher rules: a driver home before the yellow is classified by
  -- their finish.
  if race.caution then
    local da, db = cautionDownOf(a), cautionDownOf(b)
    if da and db and da ~= db then return da < db end
    local pa, pb = a.cautionPos, b.cautionPos
    if pa and pb then
      if pa ~= pb then return pa < pb end
    elseif pa ~= pb then
      return pa ~= nil
    end
  end
  -- 1. Laps completed.
  if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
  -- 2. Checkpoints cleared on the current lap.
  local ca, cb = a.cpCleared or 0, b.cpCleared or 0
  if ca ~= cb then return ca > cb end
  -- 3. Distance to the next checkpoint (none reported sorts behind).
  local da, db = a.distNext or math.huge, b.distNext or math.huge
  if da ~= db then return da < db end
  -- Stable fallbacks: laps led, then the starting grid.
  if a.lapsLed ~= b.lapsLed then return a.lapsLed > b.lapsLed end
  return (a.gridPos or math.huge) < (b.gridPos or math.huge)
end

-- GAP (behind the leader) and INTERVAL (behind the car ahead), each measured at
-- THIS driver's last checkpoint: a subtraction off one clock, computed in the
-- position walk at no extra cost. Not in qualifying, where the order is the best
-- lap and the panel computes the gap from those.
function progress.delta(other, lap, cp, mine)
  if not other or other.splits == nil then return nil end
  local theirs = other.splits[lap]
  theirs = theirs and theirs[cp]
  if not theirs then return nil end
  local d = mine - theirs
  -- Negative is clamped to 0: the order changed since that checkpoint, and a
  -- minus sign under "behind" reads as a bug.
  if d < 0 then d = 0 end
  -- Three decimals: the stamp already carries the reporting client's ping.
  return math.floor(d * 1000 + 0.5) / 1000
end

-- Who is about to be lapped, and by whom. NOT read off the classification: a
-- lapped car sorts below the whole lead lap, while the car about to pass it is
-- near the top. Sorted by how far round the lap (checkpoints, then distance) is
-- TRACK order; where the car behind is on a higher lap, it is lapping. The gap
-- compares each driver's stamp on their OWN lap at the same checkpoint.
local function markBlueFlags(list)
  local track = {}
  for _, rec in ipairs(list) do
    -- Circulating cars that have reported a position.
    if (rec.status == 'racing') and rec.splitLap and rec.cpCleared then
      track[#track + 1] = rec
    end
  end
  table.sort(track, function (a, b)
    local ca, cb = a.cpCleared or 0, b.cpCleared or 0
    if ca ~= cb then return ca > cb end
    local da, db = a.distNext or math.huge, b.distNext or math.huge
    if da ~= db then return da < db end
    return (a.id or 0) < (b.id or 0)
  end)

  for i = 1, #track - 1 do
    local ahead, behind = track[i], track[i + 1]
    -- The car BEHIND on a higher lap: lapping, not racing.
    if (behind.currentLap or 0) > (ahead.currentLap or 0) then
      local cp    = behind.splitCp
      local onLap = behind.splits and behind.splits[behind.splitLap]
      local mine  = onLap and onLap[cp]
      -- The backmarker's stamp at that point on THEIR lap.
      local theirs = ahead.splits and ahead.splits[ahead.currentLap]
      theirs = theirs and theirs[cp]
      -- Subtracted here, not through progress.delta: negative means the lapping
      -- car is not behind at all, and clamping it to 0 would flag a pair drawing
      -- apart.
      local gap = (mine and theirs) and (mine - theirs) or nil
      if gap and gap >= 0 then
        -- Wider to stay lit than to light. Off `blueWas`: assignPositions has
        -- already cleared `blue` for this pass.
        local band = ahead.blueWas and CFG.blueFlagClear or CFG.blueFlagWithin
        if gap <= band then
          ahead.blue    = true
          behind.lapping = true
        end
      end
    end
  end
end

local function assignPositions(list)
  local leader = list[1]
  local quali  = race.sessionKind == 'quali'
  -- Per-class positions: one walk of the already-sorted list, counting per
  -- class. Only when a class is in use.
  local seen = nil
  for _, rec in ipairs(list) do
    if rec.class then seen = {}; break end
  end
  for i, rec in ipairs(list) do
    rec.position = i
    rec.classPos = nil
    if seen and rec.class then
      -- DNFs and DSQs keep a class place, like an overall one.
      seen[rec.class] = (seen[rec.class] or 0) + 1
      rec.classPos = seen[rec.class]
    end
    rec.gap, rec.intv = nil, nil
    -- Cleared every pass so a flag never outlives what earned it; the old value
    -- is kept for the hysteresis.
    rec.blueWas = rec.blue
    rec.blue, rec.lapping = nil, nil
    -- A DNF or DSQ has no meaningful distance to anybody.
    if not quali and rec.status ~= 'dnf' and rec.status ~= 'dsq' and rec.splitLap then
      local lap, cp = rec.splitLap, rec.splitCp
      local onLap = rec.splits and rec.splits[lap]
      local mine  = onLap and onLap[cp]
      if mine then
        rec.gap  = progress.delta(leader, lap, cp, mine)
        rec.intv = progress.delta(list[i - 1], lap, cp, mine)
      end
    end
  end
  -- No blue flags in qualifying (no lapping) or while neutralised.
  if not quali and not race.caution and not race.cautionPending and not race.pacing then
    markBlueFlags(list)
  end
  return list
end

-- The driver fields that go over the wire (a fifth off the busiest message).
-- ANY field the UI reads off a driver row must be listed here, or it is nil in
-- the app; tests/ui_bindings_test.lua checks the template against this list.
local DRIVER_WIRE_FIELDS = {
  'id', 'name', 'alias', 'status', 'spectating',
  'gridPos', 'customGrid', 'position',
  'qualiBest', 'qualiLaps', 'outLap', 'raceBest', 'currentLap', 'lapsLed', 'cpCleared',
  'finishTime', 'resets', 'resetsBlocked',
  'jokerTaken', 'jokerLap', 'outReason', 'dnfPos', 'heldPos', 'bystander',
  -- Laps down at the caution.
  'cautionDown',
  -- The blue flag, from both ends; each client reads its own row.
  'blue', 'lapping',
  -- The heat program per driver.
  'heat', 'heatPos', 'transferred',
  -- Class and class place, nil unless a class is in use.
  'class', 'classPos',
  -- Gap and interval.
  'gap', 'intv',
  -- Garage List verdict, three-valued (see newRecord).
  'carOk',
}

-- The projection buffer lives ON the record and is reused: no allocation per
-- broadcast.
local function driverForWire(rec)
  local wire = rec.wire
  if not wire then
    wire = {}
    rec.wire = wire
  end
  for i = 1, #DRIVER_WIRE_FIELDS do
    local key = DRIVER_WIRE_FIELDS[i]
    wire[key] = rec[key]
  end
  return wire
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
    -- Race order (raceOrderLess).
    table.sort(list, raceOrderLess)
  end
  -- Positions are stamped on the REAL records, which the rest of the file reads.
  assignPositions(list)
  local wire = {}
  for i = 1, #list do wire[i] = driverForWire(list[i]) end
  return wire
end

-- Forward declarations for code defined far below its callers (a later local
-- would be a nil global here): the garage snapshot, audit, rejudge and removal.
local garageSnapshot
local garageAudit
local garageRejudge
local rejectVehicle

-- Results folder resolver, used by broadcastState (tests/scope_test.lua).
local resultsFolderPath

-- Assigned with the cup module far below; declared here because display-name
-- changes up here must refresh the roster view (a later local was a silent nil).
local broadcastCupState

-- Stamped into every state broadcast; clients drop unstamped ones (an outdated
-- copy of this plugin installed alongside).
local RM_PROTOCOL = 2

-- Build stamp, so the separately deployed halves can be compared at a glance (a
-- stale app.js silently ignores a missing scope function). It IS the released
-- package version. Bump it in ALL SEVEN places on every change that needs
-- redeploying:
--
--   server/RaceManager/main.lua          RM_BUILD   (here)
--   lua/ge/extensions/raceManager.lua    RM_BUILD
--   ui/modules/apps/RaceManager/app.js   APP_BUILD
--   ui/modules/apps/RaceManager/app.json version
--   ui/modules/apps/RaceManagerLights/app.json version
--   ui/modules/apps/RaceManagerRadar/app.json version
--   tools/deploy.py                      RELEASE_NAME
--
-- tests/wiring_test.lua fails if they disagree.
local RM_BUILD = '0.19.0'

-- The ghost roster on the wire: absolute END times on race.time, so a late
-- client works out a shorter remainder, never a longer one.
local function ghostRoster()
  local list = {}
  for pid, g in pairs(ghosts) do
    list[#list + 1] = { pid = pid, endsAt = g.startedAt + g.duration }
  end
  return list
end

-- WHO IS OUT OF THIS RACE BUT STILL ON THE MAP: player ids every client ghosts.
-- A finisher keeps their car, collision off. AUTHORITATIVE: a pid absent has no
-- finished ghost, so missed packets, late joins and disconnects self-correct.
-- Includes DNF and DSQ, and, while a session runs, every driver with status
-- 'waiting' (another heat's driver, a sit-out, a mid-session arrival), who are
-- as dangerous to it as a finisher. Qualifying counts too. Empty once the
-- session is over, which is the un-ghost at the flag.
-- (`bystander` alone only ghosts the field on that driver's own client; naming
-- them here makes it mutual.) 'grid' counts: a hold can stand for minutes.
local function finishedRoster()
  local list = {}
  if race.phase ~= 'racing' and race.phase ~= 'countdown'
     and race.phase ~= 'qualifying' and race.phase ~= 'grid' then return list end
  for _, rec in pairs(players) do
    local st = rec.status
    if st == 'finished' or st == 'dnf' or st == 'dsq' or st == 'waiting' or st == 'called' then
      list[#list + 1] = rec.id
    end
  end
  return list
end

-- Drivers practising ghosted: rec.practicing (set on an approved practice load,
-- cleared by RM_PracticeEnd, a disconnect or a grid forming) and their own
-- rec.practiceGhost choice. Empty outside 'waiting', so a stale flag never
-- ghosts a session car. On `race`: no locals to spare.
race.practiceRoster = function ()
  local list = {}
  if race.phase ~= 'waiting' or race.derbyUnderWay() then return list end
  for _, rec in pairs(players) do
    if rec.practicing and rec.practiceGhost then list[#list + 1] = rec.id end
  end
  return list
end

-- The client ghosts itself the instant the reset fires and tells the server
-- after: this is the record and the relay to every OTHER client, plus one clock
-- and one copy for late joiners. Never permission.
local function broadcastGhost(pid, g)
  MP.TriggerClientEvent(-1, 'RM_Ghost', Util.JsonEncode({
    pid       = pid,
    active    = g ~= nil,
    startedAt = g and g.startedAt or nil,
    duration  = g and g.duration or nil,
  }))
end

-- Drop one player's ghost and tell everyone; safe when there is none.
local function clearGhost(pid, reason)
  if not ghosts[pid] then return false end
  local held = race.time - ghosts[pid].startedAt
  ghosts[pid] = nil
  broadcastGhost(pid, nil)
  local rec = players[pid]
  print(string.format('[RaceManager] %s: ghost ended after %.1fs (%s)',
    rec and rec.name or ('pid ' .. tostring(pid)), held, reason or 'clear'))
  return true
end

-- Every ghost dropped at once: nothing stays ghosted across a session boundary.
local function clearAllGhosts(reason)
  local any = false
  for pid in pairs(ghosts) do
    ghosts[pid] = nil
    broadcastGhost(pid, nil)
    any = true
  end
  if any then
    print('[RaceManager] All reset ghosts cleared (' .. tostring(reason or 'session change') .. ')')
  end
  return any
end

local function broadcastState(targetPid)
  -- The Garage List goes out on RM_Garage when it changes. KEPT, OFF:
  -- race.garageOnUpdate = true puts it on every push for a pre-RM_Garage client.
  local garageInfo = race.garageOnUpdate and garageSnapshot and garageSnapshot() or {}
  -- Per-player admin status, on TARGETED sends only (RM_RequestState answers
  -- "am I still logged in").
  local selfAdmin = nil
  local selfRole = nil
  local selfSpectating = nil
  if targetPid then
    selfAdmin = isAuthenticated(targetPid)
    selfRole  = authenticatedPlayers[targetPid]
    local selfRec = players[pidKey(targetPid)]
    -- Not `x and y == true or nil`: that idiom can never yield false, so
    -- "spectating off" dropped out of the JSON and the panel kept the old value.
    if selfRec then selfSpectating = selfRec.spectating == true end
  end
  local payload = Util.JsonEncode({
    rmProtocol   = RM_PROTOCOL,
    serverBuild  = RM_BUILD,
    phase        = race.phase,
    -- Which session the shared lifecycle is running.
    sessionKind  = race.sessionKind,
    sessionLaps  = (race.sessionKind == 'quali')
      and (race.qualiLapLimit > 0 and race.qualiLapLimit or 0) or raceDistance(),
    raceTime     = race.time,
    totalLaps    = race.totalLaps,
    -- Regulations: clients enforce locally, the server is authoritative.
    maxResets    = race.maxResets,
    resetMode    = race.resetMode,
    jokerEnabled = race.jokerEnabled,
    -- Race entry and the grid. youSpectating: targeted sends only.
    youSpectating = selfSpectating,
    entrants     = entrantCount(),
    gridMode     = race.gridMode,
    startSlots   = race.startSlots,
    readyCheck   = race.readyCheck,
    pointToPoint = race.pointToPoint,
    dragStrip    = race.dragStrip,
    -- The publicly loaded layout, '' for none: the Layouts menu's LOADED tag.
    -- A private (forEditing) load never moves it.
    layoutName   = type(race.layout) == 'table' and race.layout.name or '',
    -- Whether this track has branch gates (the gates ride RM_ApplyLayout).
    hasBranches  = #race.branches > 0,
    gridOffLine  = race.gridOffLine,
    -- So the panel can grey the joker toggle and say why.
    jokerGates   = race.jokerGates,
    flag         = race.flag,
    -- The pace lap: the rule (the client's lap target is one crossing further
    -- out, see effectiveLapTarget) and the condition (yellow alone cannot say
    -- "form up" rather than "incident").
    paceLap      = race.paceLap,
    pacing       = race.pacing,
    -- The caution: a neutralised race, so the panel says POSITIONS FROZEN.
    caution      = race.caution,
    cautionLaps  = race.caution and race.cautionLaps or nil,
    -- Called and not yet official: the board is still live.
    cautionPending = race.cautionPending,
    -- A restart is called; the panel offers Cancel.
    restartPending = race.restartPending,
    -- The free pass rule, and who has it this caution.
    luckyDog     = race.luckyDog,
    cautionLucky = race.cautionLucky,
    -- The heat program; heatLaps because the flags are waved client-side and
    -- must reach the same distance as sessionLapTarget.
    heatCount    = race.heatCount,
    heatTransfer = race.heatTransfer,
    heatCurrent  = race.heatCurrent,
    heatsDrawn   = race.heatsDrawn,
    heatLaps     = race.heatLaps,
    heatDraw     = race.heatDraw,
    -- Fastest lap of the session, painted gold.
    bestLapPid   = race.bestLapPid,
    bestLapTime  = race.bestLapTime,
    -- Ghost rules every client runs, and the authoritative rosters (a client
    -- that joined mid-ghost needs them).
    ghostOnReset = CFG.ghostOnReset,
    ghostMinSec  = CFG.ghostMinSeconds,
    ghostMaxSec  = CFG.ghostMaxSeconds,
    ghosts       = ghostRoster(),
    ghostFinished = finishedRoster(),
    ghostPractice = race.practiceRoster(),
    -- Qualifying rules and clock.
    ghostQuali     = race.ghostQuali,
    -- Does this session open with an out lap (outLapOwed, races included; the
    -- name is historical). Per-driver owing rides on the rows (`outLap`).
    qualiOutLap    = outLapOwed(),
    qualiLapLimit  = race.qualiLapLimit,
    qualiTimeLimit = race.qualiTimeLimit,
    qualiTime      = race.qualiTime,
    qualiLeft      = race.qualiTimeLimit > 0
      and math.max(race.qualiTimeLimit - race.qualiTime, 0) or nil,
    -- Final lap, on the broadcast so a reconnecting client learns it too.
    finalLap       = race.finalLap,
    finalLapLeft   = race.finalLap and math.max(race.finalLapLeft, 0) or nil,
    -- Timed races: raceLeft counts down, raceExpired waits on the leader,
    -- lastLapNum is the lap everyone finishes on.
    raceMode       = race.raceMode,
    raceTimeLimit  = race.raceTimeLimit,
    -- From the GREEN, as RM_Tick enforces it.
    raceLeft       = race.raceTimeLimit > 0
      and math.max(race.raceTimeLimit - raceElapsed(), 0) or nil,
    -- The race clock counting UP from the green (raceTime is the session clock
    -- ghost timers anchor to).
    raceClock      = raceElapsed(),
    -- GET READY is out.
    greenReady     = (race.pacing or race.restartPending) and race.greenReady or nil,
    -- Inline phase test: sessionRunning is declared further down.
    clockStopped   = race.flag == 'red'
      and (race.phase == 'racing' or race.phase == 'qualifying') or nil,
    raceExpired    = race.raceExpired,
    lastLapNum     = race.lastLapNum,
    -- Approved vehicle list (Module 4), mode ('parts' | 'strict') and set names.
    garage        = garageInfo.list,
    garageEnforce = garageInfo.enforce,
    garageMode    = garageInfo.mode,
    garageSets    = garageInfo.sets,
    -- Nametag aliases: the server only holds the switch.
    nametags      = race.nametags,
    -- Someone is logged in to run the night.
    adminPresent = next(authenticatedPlayers) ~= nil,
    -- Targeted sends only: either tier (youRole narrows it). A client that
    -- never sees youRole (old server, offline) is a full admin.
    youAreAdmin  = selfAdmin,
    youRole      = selfRole,
    -- The results folder, for admin sends only; nil if unresolved.
    resultsPath  = selfAdmin and resultsFolderPath() or nil,
    drivers      = buildDrivers(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

-- Out of the session (finished, DNF, derby eliminated). `source` scopes the lock
-- so race and derby never release each other's spectators.
local function forceSpectate(pid, reason, source, place)
  MP.TriggerClientEvent(pid, 'RM_ForceSpectate', Util.JsonEncode({
    reason = reason or 'You are out of this session',
    source = source or 'race',
    -- Their finishing place, locked at the crossing (drivers already home).
    place  = place,
  }))
end

local function releaseSpectators(source, targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_ReleaseSpectate',
    Util.JsonEncode({ source = source or 'race' }))
end

-- The server picks the slot; the client places the car (nil clears).
-- `order`/`count` stagger the field's placement.
local function assignGridSlot(pid, slot, order, count)
  MP.TriggerClientEvent(pid, 'RM_GridAssign', Util.JsonEncode({
    slot = slot, order = order, count = count,
  }))
end

-- ---------------------------------------------------------------------------
-- Ready check
-- ---------------------------------------------------------------------------
-- With race.readyCheck, forming the grid CALLS each driver: a slot, status
-- 'called', and a ghost (bystander, finishedRoster) until they press Ready.
-- Anyone still called at the lights sits out. On `race` for the ceiling.
race.callToGrid = function (rec, gridPos)
  rec.gridPos   = gridPos
  rec.status    = 'called'
  rec.bystander = true
  assignGridSlot(rec.id, nil)
end

-- Onto the slot and held. A lone ready-up lands at once (order 1 of 1).
race.readyUp = function (rec, order, count)
  rec.status    = 'gridded'
  rec.bystander = nil
  assignGridSlot(rec.id, rec.gridPos, order or 1, count or 1)
end

-- A late arrival (or a rejoin from Spectate) goes to the back of the grid, not
-- past the last placed start position.
race.callLate = function (rec)
  if race.phase ~= 'grid' or not race.readyCheck or not isEntrant(rec) then return false end
  if rec.status == 'called' or rec.status == 'gridded' then return false end
  local nextPos = (race.gridSize or 0) + 1
  if race.startSlots > 0 and nextPos > race.startSlots then
    MP.SendChatMessage(rec.id, '[RaceManager] The grid is full: every start position '
      .. 'is taken. You are in the next one.')
    return false
  end
  race.gridSize = nextPos
  race.callToGrid(rec, nextPos)
  return true
end

-- How many are on their slots, and how many have been called in all.
race.readyCounts = function ()
  local ready, called = 0, 0
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then ready = ready + 1
    elseif rec.status == 'called' then called = called + 1 end
  end
  return ready, ready + called
end

-- Chat to the logged-in admins (the derby and drag modules use it too).
race.tellAdmins = function (msg)
  for adminPid in pairs(authenticatedPlayers) do
    MP.SendChatMessage(adminPid, '[RaceManager] ' .. msg)
  end
end

-- Told once, when the last driver readies.
race.announceIfAllReady = function ()
  local ready, total = race.readyCounts()
  if total == 0 or ready < total then return end
  race.tellAdmins(string.format('Everyone is ready (%d/%d). Start when you like.', ready, total))
end

-- At the start: anyone still 'called' sits out, ghosted. Returns false (and
-- changes nothing) when drivers were called and nobody is ready.
race.dropUnready = function ()
  local ready, out = 0, {}
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then ready = ready + 1
    elseif rec.status == 'called' then out[#out + 1] = rec end
  end
  if ready == 0 and #out > 0 then return false end
  local names = {}
  for _, rec in ipairs(out) do
    rec.status, rec.gridPos, rec.bystander = 'waiting', nil, true
    names[#names + 1] = rec.name
    MP.TriggerClientEvent(rec.id, 'RM_Notice', Util.JsonEncode({
      kind = 'session', msg = 'The session started without you',
      sub = 'You were not ready. You can watch, and you are in the next one.',
    }))
  end
  if #names > 0 then
    table.sort(names)
    MP.SendChatMessage(-1, '[RaceManager] Starting without ' .. table.concat(names, ', ')
      .. ' (not ready).')
    print('[RaceManager] Not ready at the start, sitting out: ' .. table.concat(names, ', '))
  end
  return true
end

-- Tell the FIELD something, in BeamNG's own HUD: a regular client has no chat
-- app, so SendChatMessage(-1) reaches only admins. Chat stays for a reply to
-- the admin who pressed something and for records (the results path). `color`
-- picks the flash for a flag notice.
local function notifyField(kind, msg, sub, color)
  MP.TriggerClientEvent(-1, 'RM_Notice', Util.JsonEncode({
    kind = tostring(kind or 'session'), msg = tostring(msg or ''), sub = sub,
    color = color,
  }))
end

local function broadcastCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_Countdown', Util.JsonEncode({ count = count }))
end

-- ---------------------------------------------------------------------------
-- Admin authentication events
-- ---------------------------------------------------------------------------
-- A login: ONE FIELD, EITHER TIER (admin tried first). A miss clears any prior
-- flag for the session.
function RM_onLogin(pid, rawData)
  local pass = decodeString(rawData, 'password')
  local role = auth.roleOf(pass)
  if role then
    authenticatedPlayers[pid] = role
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({
      success = true, role = role,
    }))
    -- The layout list is privilege-dependent (drivers see only practice-approved
    -- ones), so a login resends it: nothing else would.
    -- Through the global handler: sendLayoutList is declared far below and would
    -- be a nil global here (scope_test).
    RM_onRequestLayouts(pid)
    -- Every client's adminPresent...
    broadcastState()
    -- ...and this client personally: youAreAdmin, youSpectating and the results
    -- path only ride a targeted send, and the app's own request came before the
    -- login.
    broadcastState(pid)
    print('[RaceManager] ' .. role .. ' login OK: ' .. (MP.GetPlayerName(pid) or pid))
  else
    authenticatedPlayers[pid] = nil
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = false }))
    print('[RaceManager] Admin login FAILED: ' .. (MP.GetPlayerName(pid) or pid))
  end
end

-- An admin logs out; the broadcast keeps adminPresent accurate.
function RM_onLogout(pid)
  if authenticatedPlayers[pid] == nil then return end
  authenticatedPlayers[pid] = nil
  broadcastState()
  print('[RaceManager] Admin logged out: ' .. (MP.GetPlayerName(pid) or pid))
end

-- Rotate a master password: future logins only; sessions stay at their tier.
-- Never broadcast, only who changed it. ADMIN ONLY for both (a moderator could
-- otherwise promote themselves). `role` defaults to admin for old clients.
function RM_onChangePassword(pid, rawData)
  if not auth.requireFull(pid) then return end
  local newPass = decodeString(rawData, 'password')
  if not newPass then return end
  local which = decodeString(rawData, 'role') == auth.MOD and auth.MOD or auth.ADMIN
  -- Empty only for the moderator (it turns the tier off); an empty admin
  -- password would lock the owner out.
  if newPass == '' and which ~= auth.MOD then return end
  if which == auth.MOD then
    auth.modPw, CFG.moderatorPassword = newPass, newPass
  else
    auth.adminPw, CFG.adminPassword = newPass, newPass
  end
  -- Persisted, so a restart does not revert it.
  local label = which == auth.MOD
    and (newPass == '' and 'Moderator login turned off' or 'Moderator password changed')
    or 'Admin password changed'
  if saveConfigToDisk() then
    print('[RaceManager] ' .. label .. ' and saved to config.json')
  else
    print('[RaceManager] ' .. label .. ', but config.json could not be '
      .. 'written: it will revert on restart')
  end
  MP.TriggerClientEvent(-1, 'RM_PasswordChanged', Util.JsonEncode({
    changedBy = MP.GetPlayerName(pid) or ('Player ' .. pid),
    role      = which,
    cleared   = newPass == '',
  }))
  print('[RaceManager] ' .. label .. ' by ' .. (MP.GetPlayerName(pid) or pid))
  -- Turning the tier OFF signs out its sessions (a rotation never does): they
  -- are told their login lapsed, which brings the login box back.
  if which == auth.MOD and newPass == '' then
    local dropped = 0
    for other, role in pairs(authenticatedPlayers) do
      if role == auth.MOD then
        authenticatedPlayers[other] = nil
        dropped = dropped + 1
        MP.TriggerClientEvent(other, 'RM_LoginResult', Util.JsonEncode({
          success = false, lapsed = true,
        }))
      end
    end
    if dropped > 0 then
      print('[RaceManager] Moderator login turned off: ' .. dropped
        .. ' session(s) signed out')
      broadcastState()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------
-- BeamMP's FS API is not in every build (nor the tests), so the fallback is a
-- shell command, which differs on Windows: cmd has no "mkdir -p" and no "ls".
local IS_WINDOWS = package.config:sub(1, 1) == '\\'

local function nativePath(path)
  if IS_WINDOWS then return (path:gsub('/', '\\')) end
  return path
end

local function makeDirectory(dir)
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(dir)
  elseif IS_WINDOWS then
    -- cmd's mkdir creates intermediates; "exists" is the normal case, so muted.
    os.execute('mkdir "' .. nativePath(dir) .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. dir .. '"')
  end
end

-- File names (not paths) directly inside dir; empty when it does not exist.
local function listDirectory(dir)
  local names = {}
  if FS and FS.ListFiles then
    for _, entry in pairs(FS.ListFiles(dir) or {}) do
      local name = tostring(entry):match('[^/\\]+$')
      if name then names[#names + 1] = name end
    end
    return names
  end
  local cmd = IS_WINDOWS
    and ('dir /b "' .. nativePath(dir) .. '" 2>nul')
    or  ('ls -1 "' .. dir .. '" 2>/dev/null')
  local p = io.popen(cmd)
  if p then
    for name in p:lines() do
      name = name:gsub('%s+$', '')
      if name ~= '' then names[#names + 1] = name end
    end
    p:close()
  end
  return names
end

local function removeFile(path)
  if FS and FS.Remove then return FS.Remove(path) ~= false end
  return os.remove(path) ~= nil
end

-- ---------------------------------------------------------------------------
-- Results logging
-- ---------------------------------------------------------------------------
-- Results: one .txt per session, written when it ends.
-- CODE AND DATA IN TWO FOLDERS: the .lua files in SERVER_DIR are replaced by
-- every deploy; everything the server owns (tracks, cup, roster, garage,
-- settings, results) lives under DATA_DIR and is never written by a release.
local SERVER_DIR  = 'Resources/Server/RaceManager'
local DATA_DIR    = SERVER_DIR .. '/Data'
local RESULTS_DIR = DATA_DIR .. '/results'

local function fmtLap(t)
  if not t then return 'no time' end
  local m = math.floor(t / 60)
  return string.format('%d:%06.3f', m, t - m * 60)
end

local function ensureResultsDir()
  makeDirectory(RESULTS_DIR)
end

-- The results folder as an absolute path, resolved ONCE (it shells out, and is
-- asked on every admin broadcast). nil rather than a guess.
local resultsAbsPath = nil
local resultsAbsAsked = false
resultsFolderPath = function ()
  if resultsAbsAsked then return resultsAbsPath end
  resultsAbsAsked = true
  local ok, pipe = pcall(io.popen, IS_WINDOWS and 'cd' or 'pwd')
  if ok and pipe then
    local cwd = pipe:read('*l')
    pipe:close()
    if type(cwd) == 'string' and cwd ~= '' then
      cwd = cwd:gsub('%s+$', '')
      -- Forward slashes; the backslash as a char code (one escape from a
      -- string that does not compile).
      resultsAbsPath = cwd:gsub(string.char(92), '/'):gsub('/$', '')
        .. '/' .. RESULTS_DIR
    end
  end
  print('[RaceManager] Results folder: ' .. tostring(resultsAbsPath or RESULTS_DIR))
  return resultsAbsPath
end

-- A timestamped path that never overwrites (_2, _3 within one second).
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
  for _, name in ipairs(listDirectory(RESULTS_DIR)) do
    if name:match('%.txt$') then names[#names + 1] = name end
  end
  return names
end

local function clearResultsCache()
  local removed = 0
  for _, name in ipairs(listResultFiles()) do
    if removeFile(RESULTS_DIR .. '/' .. name) then removed = removed + 1 end
  end
  return removed
end

-- Results are a SNAPSHOT under the name raced, so an alias also carries the
-- real guest name: the only thread back to the session.
local function aliasNote(rec)
  if not aliasOf(rec) then return '' end
  return '  [' .. rec.name .. ']'
end

-- Qualifying classification: the locked grid if any, else best lap. Kept
-- independent of the race, so pole and winner stay distinct.
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

-- Did this driver take part? `players` is everyone CONNECTED (a heat leaves
-- most of the server out). A grid slot is the rule; the other tests guard it,
-- because dropping a driver who raced is worse than listing one who did not.
local function tookPart(rec)
  if rec == nil then return false end
  return rec.gridPos ~= nil
    or rec.finishTime ~= nil
    or (rec.currentLap or 0) > 0
    or rec.status == 'dnf' or rec.status == 'dsq'
end

-- Race classification (raceOrderLess), PARTICIPANTS ONLY: the results file,
-- awards, cup round and heat transfer all read this, and a driver waiting for
-- their heat was being banked cup points. The live board (buildDrivers) still
-- shows everybody.
local function raceClassification()
  local list = {}
  for _, rec in pairs(players) do
    if tookPart(rec) then list[#list + 1] = rec end
  end
  table.sort(list, raceOrderLess)
  return list
end

-- Fastest lap, half-distance leader, and the hard charger, for the results file
-- and the cup's bonuses alike (one rule). Pure; `final` saves a second sort.
local function sessionAwards(final)
  final = final or raceClassification()
  local awards = {
    -- Tracked incrementally (RM_onLap).
    fastestLapPid = race.bestLapPid,
    fastestLapTime = race.bestLapTime,
  }

  -- Half-distance leader: first to complete lap ceil(n/2) (lapFirsts). None in
  -- a one-lap race.
  awards.halfWayLap = math.ceil(race.totalLaps / 2)
  awards.halfWayPid = (race.totalLaps >= 2) and lapFirsts[awards.halfWayLap] or nil

  -- Hard charger: most places gained from grid to finish, classified finishers
  -- only, gain above zero; ties to the higher finisher.
  for i, rec in ipairs(final) do
    local classified = rec.finishTime ~= nil and rec.status ~= 'dsq'
    local start = rec.gridPos
    if classified and start then
      local gain = start - i
      if gain > 0 and (awards.hardChargerGain == nil or gain > awards.hardChargerGain) then
        awards.hardChargerPid  = rec.id
        awards.hardChargerGain = gain
        awards.hardChargerFrom = start
        awards.hardChargerTo   = i
      end
    end
  end
  return awards
end

-- How long this race is, in words, from one place.
local function raceLengthLabel(laps)
  laps = laps or race.totalLaps
  if race.pointToPoint then return 'point to point, driven once' end
  if race.raceMode == 'timed' then
    return math.floor(race.raceTimeLimit / 60) .. ' min + 1 lap'
  end
  if race.raceMode == 'endurance' then
    return laps .. ' laps or ' .. math.floor(race.raceTimeLimit / 60)
      .. ' min + 1 lap, whichever comes first'
  end
  return laps .. (laps == 1 and ' lap' or ' laps')
end

local function buildResultsText(cupRound)
  local quali = qualiClassification()
  local final = raceClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- Laps run per driver: currentLap counts crossings (a finisher's stops on the
  -- finishing lap; a pace lap is a crossing, not a lap).
  local pace = race.racePaceLapRun and 1 or 0
  local function lapsRun(rec)
    local n = (rec.currentLap or 0) - (rec.finishTime and 0 or 1) - pace
    return n > 0 and n or 0
  end
  local leaderLaps = 0
  for _, rec in ipairs(final) do
    local n = lapsRun(rec)
    if n > leaderLaps then leaderLaps = n end
  end
  local distance = raceDistance()
  -- A timed race's distance is the laps it ran; a lap race says so if cut short.
  local ran = not race.pointToPoint and (race.raceMode ~= 'laps' or leaderLaps < distance)

  add('==================================================')
  add(' RACE MANAGER - SESSION RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Race distance: %s%s%s | Drivers: %d',
    raceLengthLabel(distance),
    race.racePaceLapRun and ' + pace lap (not counted in Laps)' or '',
    ran and string.format(', %d lap%s run', leaderLaps, leaderLaps == 1 and '' or 's') or '',
    #final))
  -- Cautions, which explain a finishing order that looks wrong.
  if race.cautionCount > 0 then
    add(string.format(' Cautions: %d, over %d lap%s',
      race.cautionCount, race.cautionLaps, race.cautionLaps == 1 and '' or 's'))
  end
  add(string.format(' Regulations: resets %s | joker lap %s',
    race.maxResets < 0 and 'unlimited'
      or (race.maxResets == 0 and 'not allowed' or tostring(race.maxResets) .. ' per driver'),
    race.jokerEnabled and 'required exactly once' or 'disabled'))
  add('==================================================')
  add('')
  add('--- QUALIFYING RESULTS ---')
  -- The lap limit counts TIMED laps; the out lap is said separately.
  add(string.format(' Format: %s%s%s%s',
    race.ghostQuali and 'ghost mode' or 'standard',
    race.qualiOutLapRun and ', out lap not timed' or '',
    race.qualiLapLimit > 0 and (', ' .. race.qualiLapLimit .. ' timed lap limit') or '',
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
  -- Regulation columns only when armed, so a plain race exports as always.
  local jokerCol  = race.jokerEnabled and string.format(' %-7s', 'Joker') or ''
  local resetCol  = race.maxResets >= 0 and string.format(' %-6s', 'Resets') or ''
  -- The class column, only when one was run, read off the classification (what
  -- was RUN; a retag after the flag must not rewrite it).
  local classed = false
  for _, rec in ipairs(final) do
    if rec.class then classed = true break end
  end
  local classCol = classed and string.format(' %-12s', 'Class') or ''
  -- 'Race Time' is padded only when a column follows it.
  local tail = classCol .. jokerCol .. resetCol
  add(string.format('%-5s %-6s %-22s %-10s %-9s %-5s %s%s',
    'Pos', 'Start', 'Driver', 'Best Lap', 'Laps Led', 'Laps',
    tail ~= '' and string.format('%-10s', 'Race Time') or 'Race Time', tail))
  local awards = sessionAwards(final)
  for i, rec in ipairs(final) do
    local excluded   = rec.status == 'dsq'
    local classified = rec.finishTime ~= nil and not excluded
    local pos, finish
    if excluded then
      pos, finish = 'DSQ', rec.outReason or 'Disqualified'
    elseif classified then
      pos, finish = 'P' .. i, fmtLap(rec.finishTime)
    else
      -- A DNF keeps the place it was running in, in the reason text (the Pos
      -- column is fixed width). Finishers stay above every retirement.
      pos = 'DNF'
      finish = (rec.outReason or 'DNF')
        .. (rec.heldPos and (' (was P' .. rec.heldPos .. ')') or '')
    end
    local tag = (i == 1 and classified) and '  << RACE WINNER' or ''
    local jokerVal = race.jokerEnabled
      and string.format(' %-7s', (rec.jokerTaken or 0) == 0 and 'missed'
        or ('lap ' .. tostring(rec.jokerLap or '?'))) or ''
    -- Blocked attempts appended ("3/3+2").
    local resetVal = race.maxResets >= 0
      and string.format(' %-6s', string.format('%d/%d%s', rec.resets or 0, race.maxResets,
        (rec.resetsBlocked or 0) > 0 and ('+' .. rec.resetsBlocked) or '')) or ''
    -- "GT3 P2" in one cell; an unclassified driver in a classed race gets "-".
    local classVal = classed and string.format(' %-12s',
      rec.class and (rec.class .. (rec.classPos and (' P' .. rec.classPos) or ''))
        or '-') or ''
    add(string.format('%-5s %-6s %-22s %-10s %-9d %-5d %-10s%s%s%s%s%s',
      pos, rec.gridPos and ('P' .. rec.gridPos) or '-',
      displayName(rec), fmtLap(rec.raceBest), rec.lapsLed or 0, lapsRun(rec), finish,
      classVal, jokerVal, resetVal, aliasNote(rec), tag))
  end
  if #final == 0 then add('(no drivers)') end
  -- PER-CLASS RESULTS: a league running two classes publishes two results. The
  -- overall order above stays the truth on the road. Same classification, walked
  -- once per class.
  if classed then
    local order, seen = {}, {}
    for _, rec in ipairs(final) do
      if rec.class and not seen[rec.class] then
        seen[rec.class] = true
        order[#order + 1] = rec.class
      end
    end
    -- Classes in the order their leading car finished.
    for _, cls in ipairs(order) do
      add('')
      add('--- CLASS: ' .. cls .. ' ---')
      add(string.format('%-5s %-6s %-22s %-10s %-5s %s',
        'Pos', 'Start', 'Driver', 'Best Lap', 'Laps', 'Race Time'))
      local n = 0
      for _, rec in ipairs(final) do
        if rec.class == cls then
          n = n + 1
          local finish
          if rec.status == 'dsq' then
            finish = rec.outReason or 'Disqualified'
          elseif rec.finishTime then
            finish = fmtLap(rec.finishTime)
          else
            finish = (rec.outReason or 'DNF')
              .. (rec.classPos and (' (was P' .. rec.classPos .. ' in class)') or '')
          end
          local cpos = (rec.status == 'dsq') and 'DSQ'
            or (rec.finishTime and ('P' .. (rec.classPos or n)) or 'DNF')
          add(string.format('%-5s %-6s %-22s %-10s %-5d %s%s',
            cpos, rec.gridPos and ('P' .. rec.gridPos) or '-',
            displayName(rec), fmtLap(rec.raceBest), lapsRun(rec), finish,
            (n == 1 and rec.finishTime) and '  << CLASS WINNER' or ''))
        end
      end
    end
    add('')
  end
  -- The award lines, omitted when there is no answer.
  local halfRec = awards.halfWayPid and players[awards.halfWayPid] or nil
  local hcRec   = awards.hardChargerPid and players[awards.hardChargerPid] or nil
  if halfRec or hcRec then add('') end
  if halfRec then
    add(string.format(' HALF-WAY LEADER: %s  (led at lap %d of %d)',
      displayName(halfRec), awards.halfWayLap, race.totalLaps))
  end
  if hcRec then
    add(string.format(' HARD CHARGER: %s  (P%d -> P%d, %+d place%s)',
      displayName(hcRec), awards.hardChargerFrom, awards.hardChargerTo,
      awards.hardChargerGain, awards.hardChargerGain == 1 and '' or 's'))
  end
  -- The championship round, from the cup module (one copy of its arithmetic).
  local cupLines = cupResultsLines and cupResultsLines(cupRound) or nil
  for _, l in ipairs(cupLines or {}) do add(l) end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

-- A copy to every logged-in admin, written into their own BeamNG folder (race
-- admins often have no access to the box). Capped: one BeamMP event must carry
-- it; over the cap they are told to use the server's copy.
local MAX_RESULTS_PUSH = 60000

local function sendResultsToAdmins(name, text)
  if type(text) ~= 'string' or text == '' then return end
  local n = 0
  for pid in pairs(authenticatedPlayers) do n = n + 1 end
  if n == 0 then return end
  if #text > MAX_RESULTS_PUSH then
    for pid in pairs(authenticatedPlayers) do
      MP.SendChatMessage(pid, '[RaceManager] Results were too large to send ('
        .. #text .. ' bytes); the server copy is complete.')
    end
    print('[RaceManager] Results not sent to admins: ' .. #text .. ' bytes over the '
      .. MAX_RESULTS_PUSH .. ' limit')
    return
  end
  for pid in pairs(authenticatedPlayers) do
    MP.TriggerClientEvent(pid, 'RM_ResultsFile', Util.JsonEncode({
      name = name, text = text }))
  end
  print(string.format('[RaceManager] Results "%s" sent to %d admin(s), %d bytes',
    name, n, #text))
end

local function writeResults(cupRound)
  ensureResultsDir()
  local path = uniqueResultsPath('results')
  local text = buildResultsText(cupRound)
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(text)
  f:close()
  -- Basename only; the separator built from a char code.
  local base = path:gsub(string.char(92), '/'):match('([^/]+)$') or 'results.txt'
  sendResultsToAdmins(base, text)
  return true, path
end

-- ---------------------------------------------------------------------------
-- Joker lap ruling (Module 2)
-- ---------------------------------------------------------------------------
-- Clients police the joker live (once per race, never on lap 1) and report each
-- completion. At the flag every finisher must have taken it exactly once, or the
-- result becomes a disqualification in the results file.
local function applyJokerRuling()
  if not race.jokerEnabled then return 0 end
  -- Never on a track with no joker gates (it would disqualify every finisher);
  -- arming is refused up front too, but this is the line that matters.
  if race.jokerGates == 0 then
    print('[RaceManager] Joker ruling skipped: the track has no joker gates')
    return 0
  end
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
-- One lifecycle, two sets of rules: ask the session, not the phase name.

local function isQualiSession()
  return race.sessionKind == 'quali'
end

-- The crossing count the current session runs to, or nil (no lap target).
local function sessionLapTarget()
  -- A sprint is one traversal; race.totalLaps is left alone for the next circuit.
  if race.pointToPoint then return 1 end
  if isQualiSession() then
    if race.qualiLapLimit <= 0 then return nil end
    -- Crossings, not timed laps: the out lap goes on top of the allowance.
    return race.qualiLapLimit + (outLapOwed() and 1 or 0)
  end
  -- A race's first lap counts (it just sets no lap TIME), so a head-on out lap
  -- comes out of the distance. A timed race has no lap target; endurance keeps
  -- one.
  if race.raceMode == 'timed' then return nil end
  -- A PACE LAP is not a racing lap, so it goes on top.
  return raceDistance() + (paceLapArmed() and 1 or 0)
end

-- The status while circulating; presentation only (checks use onTrack).
local function runningStatus()
  return isQualiSession() and 'qualifying' or 'racing'
end

local function onTrack(rec)
  return rec ~= nil and (rec.status == 'racing' or rec.status == 'qualifying')
end

-- Lights out, cars circulating: laps, telemetry and the clock count.
local function sessionRunning()
  return race.phase == 'racing' or race.phase == 'qualifying'
end

-- Under way (countdown included): no rule may move under the drivers.
local function sessionUnderWay()
  return race.phase == 'countdown' or race.phase == 'racing' or race.phase == 'qualifying'
end

-- The opening of an admin command with a payload: authenticate, optionally
-- refuse mid-session (`idle`), decode. One function so no handler forgets a
-- guard; nil means return.
local function adminPayload(pid, rawData, idle)
  if not requireAuth(pid) then return nil end
  if idle and sessionUnderWay() then return nil end
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  return data
end

-- How many drivers are still circulating.
local function driversOnTrack()
  local n = 0
  for _, rec in pairs(players) do
    if onTrack(rec) then n = n + 1 end
  end
  return n
end

-- Take one driver off the track as finished: THE single path (lap target,
-- expired-clock final lap, grace timeout).
local function retireDriver(rec, reason)
  if not onTrack(rec) then return false end
  rec.status = 'finished'
  -- RACE time, from the green: the pace lap is nobody's race.
  rec.finishTime = race.time - race.greenAt
  -- The RESET ghost ends here. The finished ghost is derived from status by
  -- finishedRoster, not an event.
  clearGhost(rec.id, 'driver finished')
  -- Their place, counted at the crossing (they are already 'finished').
  local place = 0
  for _, r in pairs(players) do
    if r.status == 'finished' then place = place + 1 end
  end
  forceSpectate(rec.id, reason, 'race', place)
  return true
end

-- Retire without a finish: THE one way a record becomes a DNF. Classified
-- BEHIND THE LAST CAR THAT CAN STILL FINISH (finishers and running cars ahead),
-- so two retirements never share a place.
local function retireAsDnf(rec, reason)
  if not rec then return false end
  rec.status = 'dnf'
  rec.outReason = rec.outReason or reason
  -- Where they were running, kept apart from where they classify.
  if rec.heldPos == nil then
    rec.heldPos = rec.position or rec.gridPos
  end
  if rec.dnfPos == nil then
    local ahead = 0
    for _, other in pairs(players) do
      if other ~= rec and (onTrack(other) or other.finishTime ~= nil) then
        ahead = ahead + 1
      end
    end
    rec.dnfPos = ahead + 1
  end
  return true
end

-- Forward declaration: one grid-forming function for both entry points.
local formGrid

-- Give a field their cars back: THE mass-respawn path. Takes SNAPSHOT arrays
-- (building a list mid-release once reached only the last name), which also
-- lets the derby share it. Each participant is told its place for the stagger;
-- bystanders only get the lock lifted.
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

-- The single exit for every way a session ends: stop the clock, put every car
-- back, then that session's own rules.
local function finishSession(reason)
  MP.CancelEventTimer('RM_CountdownTick')
  -- A session ended during its pace lap must not leave `pacing` set.
  race.pacing    = false
  race.paceArmed = false
  -- The caution goes with the session; cautionCount stays for the results file.
  race.caution   = false
  -- ...and neither pending call outlives it.
  race.cautionPending = false
  race.restartPending = false
  race.cautionLucky   = nil
  thawOrder()
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  -- No reset ghost outlives the session; the respawn has its own placement ghost.
  clearAllGhosts('session ended: ' .. tostring(reason))
  if isQualiSession() then
    -- Qualifying drops back to waiting: Generate Grid comes next, ordered by these
    -- times.
    race.phase = 'waiting'
    for _, rec in pairs(players) do
      if onTrack(rec) then rec.status = 'waiting' end
    end
    -- Qualifying points are held for the race's round (no-op without a cup).
    if cupOnSessionComplete then cupOnSessionComplete('quali') end
    if race.recordsSession then race.recordsSession('quali') end
    respawnAll('race')
    broadcastState()
    MP.SendChatMessage(-1, '[RaceManager] Qualifying is over: ' .. reason .. '.')
    print('[RaceManager] Qualifying closed: ' .. reason)
    return
  end

  local excluded = applyJokerRuling()
  race.phase = 'finished'
  -- THE HEAT RESULT, recorded once final (after the joker ruling, so an excluded
  -- driver never transfers), onto the record and the identity registry.
  if race.heatCount > 0 and race.heatCurrent > 0 then
    local order = raceClassification()
    local pos, transferred = 0, 0
    for _, rec in ipairs(order) do
      -- Only the drivers in THIS heat.
      if rec.heat == race.heatCurrent then
        -- Counted within the heat, not from the list index: by heat 2 earlier
        -- heats' drivers sort above, and the index transferred nobody.
        pos = pos + 1
        rec.heatPos = pos
        -- A disqualification never transfers.
        rec.transferred = (rec.status ~= 'dsq') and (pos <= race.heatTransfer) or false
        if rec.transferred then transferred = transferred + 1 end
        rememberIdentity(rec)
      end
    end
    print(string.format('[RaceManager] Heat %d classified: %d transfer to the feature',
      race.heatCurrent, transferred))
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] HEAT %d COMPLETE: %d driver%s transferred to the feature.',
      race.heatCurrent, transferred, transferred == 1 and '' or 's'))
  end
  -- The cup is scored AFTER the joker ruling, and the round it banks is carried
  -- to the results file (a cup at its cap scores nothing, and "the current
  -- round" would then print the previous race's points).
  local cupRound = cupOnSessionComplete and cupOnSessionComplete('race') or nil
  -- After the joker ruling too: a disqualified lap sets no record.
  if race.recordsSession then race.recordsSession('race') end
  respawnAll('race')
  broadcastState()
  if excluded > 0 then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Joker lap ruling: %d driver%s disqualified for not taking the Joker Route exactly once.',
      excluded, excluded == 1 and '' or 's'))
  end
  print('[RaceManager] Race over: ' .. reason)
  local ok, wrote, pathOrErr = pcall(writeResults, cupRound)
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
-- grid through the SAME path as Generate Grid, so three laps mean three laps
-- from a standing start. Names and entry decisions survive (identity registry).
function RM_onStartQualifying(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  MP.CancelEventTimer('RM_CountdownTick')
  wipe(players)
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil
  race.time = 0.0
  race.endsAt, race.endReason = nil, nil
  race.qualiTime = 0.0
  if not formGrid('quali', MP.GetPlayerName(pid) or pid) then return end
  print(string.format('[RaceManager] Qualifying grid formed by %s (%d entrant(s), entry: %s%s%s)',
    MP.GetPlayerName(pid) or pid, entrantCount(), 'everyone races',
    race.qualiLapLimit > 0 and (', ' .. race.qualiLapLimit .. ' timed lap limit') or '',
    race.qualiTimeLimit > 0 and (', ' .. race.qualiTimeLimit .. 's limit') or ''))
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] Qualifying grid formed (%s%s). Start Countdown to begin the session.',
    race.qualiLapLimit > 0
      and (race.qualiLapLimit .. ' timed lap' .. (race.qualiLapLimit == 1 and '' or 's'))
      or 'unlimited laps',
    outLapOwed() and ' + an out lap that is not timed' or ''))
end


-- A driver retires from a running session: their own call, no admin needed. A
-- CLASSIFIED retirement (results, cup), then spectating like a finisher.
function RM_onRetire(pid)
  local rec = players[pidKey(pid)]
  if not rec then return end
  if not sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] Nothing to retire from.')
    return
  end
  if not onTrack(rec) then return end
  retireAsDnf(rec, 'Retired')
  clearGhost(rec.id, 'driver retired')
  forceSpectate(rec.id, 'You retired from the session', 'race')
  MP.SendChatMessage(-1, string.format('[RaceManager] %s RETIRED (classified P%d).',
    rec.name, rec.dnfPos or 0))
  print(string.format('[RaceManager] %s retired, classified P%s',
    rec.name, tostring(rec.dnfPos)))
  broadcastState()
end

function RM_onSetSpectating(pid, rawData)
  local rec = ensurePlayer(pid)
  if not rec then return end
  local want = true
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' and data.spectating ~= nil then
      want = data.spectating == true or data.spectating == 1
    end
  end
  -- Already in that state: answer anyway, so every press resyncs a panel that
  -- has drifted.
  if rec.spectating == want then
    broadcastState(pid)
    return
  end
  -- Neither direction mid-session: the field is decided at the grid, and leaving
  -- a running race is Retire.
  if sessionUnderWay() then
    MP.SendChatMessage(pid, want
      and '[RaceManager] A session is running. Use Retire to pull out of it; you '
        .. 'can sit the next one out once this ends.'
      or  '[RaceManager] A session is running: you can rejoin the field when it ends.')
    return
  end
  rec.spectating = want
  -- Into the registry, or the next online purge silently undoes it.
  rememberIdentity(rec)
  if want then
    -- The car stays where it is, as a ghost (a BeamMP delete is for everyone).
    rec.bystander = true
    -- Hand the slot back, or their client stays parked on the grid all race.
    rec.gridPos = nil
    rec.status  = 'waiting'
    assignGridSlot(rec.id, nil)
    MP.SendChatMessage(-1, '[RaceManager] ' .. rec.name .. ' is spectating.')
    -- The last unready driver may have been this one.
    if race.phase == 'grid' then race.announceIfAllReady() end
  else
    rec.bystander = nil
    MP.SendChatMessage(-1, '[RaceManager] ' .. rec.name .. ' rejoined the field.')
    -- While the grid is being called, rejoining means the back of it.
    race.callLate(rec)
  end
  print(string.format('[RaceManager] %s set spectating=%s', rec.name, tostring(want)))
  -- The derby and drag panels derive their fields from this list.
  if derbyEntryListChanged then derbyEntryListChanged() end
  race.dragEntryChanged()
  -- Twice: everyone gets the entrant count, and this player gets youSpectating
  -- (targeted sends only).
  broadcastState()
  broadcastState(pid)
end


-- ---------------------------------------------------------------------------
-- Qualifying session rules
-- ---------------------------------------------------------------------------
-- Nametag aliases: the server holds the SWITCH only (it cannot rename anyone).
-- Clients add a suffix through setPlayerNickSuffix (see nametag.apply).
function RM_onSetNametags(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  race.nametags = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Display names on nametags '
    .. (race.nametags and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Ghost qualifying: enforced client-side; the server holds the switch.
function RM_onSetGhostQuali(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  race.ghostQuali = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Ghost qualifying ' .. (race.ghostQuali and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Qualifying length: a lap allowance, a time limit, or neither (0). Locked
-- while a session runs.
function RM_onSetQualiLimits(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local laps = tonumber(data.laps)
  local secs = tonumber(data.seconds)
  if laps then
    laps = math.floor(laps)
    if laps < 0 then laps = 0 elseif laps > CFG.maxQualiLaps then laps = CFG.maxQualiLaps end
    race.qualiLapLimit = laps
  end
  if secs then
    secs = math.floor(secs)
    if secs < 0 then secs = 0 elseif secs > CFG.maxQualiTime then secs = CFG.maxQualiTime end
    race.qualiTimeLimit = secs
  end
  broadcastState()
  print(string.format('[RaceManager] Qualifying limits set by %s: %s laps, %s',
    MP.GetPlayerName(pid) or pid,
    race.qualiLapLimit == 0 and 'unlimited' or tostring(race.qualiLapLimit),
    race.qualiTimeLimit == 0 and 'no time limit' or (race.qualiTimeLimit .. 's')))
end

-- Close qualifying (finishSession does the work).
local function endQualifying(reason)
  if race.phase ~= 'qualifying' or not isQualiSession() then return end
  finishSession(reason)
end

-- The qualifying clock ran out. This does NOT end the session: it arms the final
-- lap, and each driver's next S/F crossing ends their session (the same removal
-- and respawn as a lap limit). Ending it outright left cars loose on a dead
-- circuit, never told.
local function beginFinalLap()
  if race.finalLap then return end
  -- Nobody out there: close cleanly instead of arming a state nothing leaves.
  if driversOnTrack() == 0 then
    endQualifying('the time limit expired')
    return
  end
  race.finalLap     = true
  race.finalLapLeft = CFG.finalLapGrace
  broadcastState()
  notifyField('session', 'TIME EXPIRED', 'The lap you are on is your '
    .. 'FINAL LAP. Your session ends as you cross the line.')
  print(string.format('[RaceManager] Qualifying time expired: final lap armed for %d driver(s)',
    driversOnTrack()))
end

-- TIMED RACE: the leader took the line after the clock expired, so `fromLap` is
-- the last lap. Everyone finishes by COMPLETING it, not at their next crossing
-- (that would end a car just behind the leader a lap early). The checkered flag
-- (race.finalLap) comes later, when the first car completes it.
local function armRaceFinalLap(fromLap, why)
  if race.lastLapNum then return end
  if driversOnTrack() == 0 then
    finishSession(why or 'the time limit expired')
    return
  end
  race.lastLapNum = fromLap
  broadcastState()
  notifyField('flag', 'FINAL LAP', 'The leader has taken the line. '
    .. 'Everyone still running finishes at the end of lap ' .. fromLap .. '.', 'white')
  print(string.format('[RaceManager] Timed race: final lap is lap %d (%s), %d driver(s) out',
    fromLap, why or 'leader crossed after the clock expired', driversOnTrack()))
end

-- Shuffle for the random grid draw, seeded from os.time once.
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

-- Fill the grid in race.gridMode's order:
--   quali     fastest best lap first, no time last
--   reverse   slowest first; no time still last (see below)
--   random    a draw
--   custom    pinned slots first, the rest by quali time
--   points    championship order; pointsrev reversed
local function orderForGrid(ordered)
  if race.gridMode == 'random' then
    return shuffle(ordered)
  end
  -- Championship order. A driver with NO cup entry goes to the back in both, or
  -- scoring nothing would be a route to pole; zero points still beats absent.
  if race.gridMode == 'points' or race.gridMode == 'pointsrev' then
    local rev = race.gridMode == 'pointsrev'
    local pts = {}
    for _, rec in ipairs(ordered) do
      pts[rec.id] = cupSeasonPoints and cupSeasonPoints(rec) or nil
    end
    table.sort(ordered, function (a, b)
      local pa, pb = pts[a.id], pts[b.id]
      if pa and pb then
        if pa ~= pb then
          if rev then return pa < pb end
          return pa > pb
        end
      elseif pa ~= pb then
        return pa ~= nil
      end
      return a.id < b.id
    end)
    return ordered
  end
  -- Reverse inverts the TIMES only. No time still goes to the back, or sitting
  -- in the pits would be the fastest way to pole.
  local reverse = race.gridMode == 'reverse'
  local function byQuali(a, b)
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then
        if reverse then return ta > tb end
        return ta < tb
      end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end
  -- THE FEATURE GRID FROM THE HEATS, in transfer order: all heat winners (by
  -- heat number), then all seconds, and so on. Non-transferring drivers still
  -- race, behind (Sit Out makes it strict); no heat at all falls back to quali.
  if race.gridMode == 'heats' then
    table.sort(ordered, function (a, b)
      local ta, tb = a.transferred == true, b.transferred == true
      if ta ~= tb then return ta end
      local pa, pb = a.heatPos, b.heatPos
      if pa and pb then
        if pa ~= pb then return pa < pb end
        return (a.heat or math.huge) < (b.heat or math.huge)
      elseif pa ~= pb then
        return pa ~= nil
      end
      return byQuali(a, b)
    end)
    return ordered
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

-- Form the grid for a session: THE one path, for Generate Grid and Start
-- Qualifying alike. Returns true when a grid was formed.
formGrid = function (kind, byName)
  -- Re-forming a called grid keeps whoever already pressed Ready.
  local reform = race.phase == 'grid'
  race.sessionKind = (kind == 'quali') and 'quali' or 'race'
  race.time = 0.0
  race.endsAt, race.endReason = nil, nil
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil

  -- Purge records no longer connected (kept for the last results file), or one
  -- would be gridded, never report a lap, and block the auto-finish. Through
  -- onlinePlayers(): mismatched keys once purged a whole grid.
  local online = onlinePlayers()
  for id in pairs(players) do
    if online[id] == nil then players[id] = nil end
  end
  -- Every connected player gets a record, identity restored by ensurePlayer.
  for id in pairs(online) do ensurePlayer(id) end

  local ordered, skipped = {}, {}
  for _, rec in pairs(players) do
    if isEntrant(rec) then
      ordered[#ordered + 1] = rec
    else
      -- Not entered: off the grid, no stale slot...
      skipped[#skipped + 1] = rec.name
      rec.gridPos = nil
      rec.status  = 'waiting'
      -- ...and a ghost both ways (finishedRoster covers the other way). A heat
      -- draw puts drivers here without anybody pressing anything.
      rec.bystander = true
      assignGridSlot(rec.id, nil)
    end
  end

  if #ordered == 0 then
    -- Never a bare "nobody joined": log who was considered and why.
    local connected = 0
    for _ in pairs(online) do connected = connected + 1 end
    print(string.format(
      '[RaceManager] Grid not formed: no entrants (%d connected, %d record(s): %s)',
      connected, #skipped,
      #skipped > 0 and table.concat(skipped, ', ') or 'none'))
    -- Empty means nobody is here, or everybody pressed Spectate.
    MP.SendChatMessage(-1, connected > 0
      and string.format('[RaceManager] Everyone on the server is spectating '
        .. '(%d connected). Press Race in PRM - Main to take part.', connected)
      or '[RaceManager] Nobody is on the server to grid.')
    return false
  end

  orderForGrid(ordered)
  -- Locks come off BEFORE the slots go out (a client with no car would drop
  -- the slot); the client coalesces the two into one ghosted operation.
  releaseSpectators('race')
  race.gridSize = #ordered
  for gridPos, rec in ipairs(ordered) do
    local wasReady = reform and rec.status == 'gridded'
    rec.gridPos    = gridPos
    rec.status     = 'gridded'
    rec.raceBest   = nil
    rec.currentLap = 0
    rec.lapsLed    = 0
    rec.finishTime = nil
    -- A new session: allowances and joker credit start over.
    rec.resets     = 0
    rec.resetsBlocked = 0
    rec.jokerTaken = 0
    rec.jokerLap   = nil
    rec.outReason  = nil
    rec.dnfPos     = nil
    rec.heldPos    = nil
    -- The clock goes back to zero, so every stamp off the old one goes too: a
    -- stale holdCorrectedAt reads as "just corrected" and suppressed the grid
    -- hold for a minute; old splits would read minutes behind.
    rec.holdCorrectedAt = nil
    rec.holdCorrections = 0
    rec.splits   = nil
    rec.splitLap = nil
    rec.splitCp  = nil
    rec.gap, rec.intv = nil, nil
    -- "This session" counters.
    rec.pitStops   = 0
    rec.ghosts     = 0
    -- A qualifying grid clears the times it replaces.
    if isQualiSession() then
      rec.qualiBest = nil
      rec.qualiLaps = 0
    end
    -- Set here as well as at GO, so the board says so during the hold.
    rec.outLap = outLapOwed()
    -- Gridded: no longer a bystander.
    rec.bystander = nil
    progress.clear(rec)
    if race.readyCheck and not wasReady then
      -- Called: placed when they press Ready.
      race.callToGrid(rec, gridPos)
    else
      -- Placed and held until GO, staggered by order.
      assignGridSlot(rec.id, gridPos, gridPos, #ordered)
    end
  end

  race.phase = 'grid'
  -- Every client gets the track again (idempotent), late joiners included.
  race.sendLayoutTo(-1)
  -- No ghost carries onto a new grid.
  clearAllGhosts('grid formed')
  -- Practice ends here too (each client stops its own off the phase change).
  for _, rec in pairs(players) do rec.practicing, rec.practiceGhost = nil, nil end
  broadcastState()
  if race.startSlots > 0 and #ordered > race.startSlots then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Warning: %d drivers but only %d start positions placed: '
        .. 'the back of the grid has nowhere to line up.', #ordered, race.startSlots))
  end
  print(string.format('[RaceManager] %s grid formed by %s (%d drivers, %s order, pole: %s)',
    isQualiSession() and 'Qualifying' or 'Race', tostring(byName), #ordered, race.gridMode,
    ordered[1] and ordered[1].name or 'n/a'))
  if race.readyCheck then
    local ready, total = race.readyCounts()
    MP.SendChatMessage(-1, string.format('[RaceManager] Grid called: press Ready in '
      .. 'PRM - Main to take your slot (%d/%d ready).', ready, total))
    race.announceIfAllReady()
  end
  return true
end

-- Generate Grid ALWAYS forms the race grid. A running QUALIFYING session is
-- ended (times scored and kept) and superseded, so "run quali, press Generate
-- Grid" works. A running RACE is refused, OUT LOUD: superseding it would throw
-- away a live result on one misclick.
function RM_onGenerateGrid(pid)
  if not requireAuth(pid) then return end
  local who = MP.GetPlayerName(pid) or pid
  if race.phase == 'racing' or race.phase == 'countdown' then
    MP.SendChatMessage(pid, '[RaceManager] A race is under way: press End Session '
      .. 'first, then Generate Grid.')
    print('[RaceManager] Generate Grid refused: a race is already running')
    return
  end
  if race.phase == 'qualifying' then
    -- Ended as End Session does, so the times are kept.
    MP.CancelEventTimer('RM_CountdownTick')
    broadcastCountdown(-1)
    finishSession('qualifying closed by ' .. who .. ' to form the race grid')
    print('[RaceManager] Qualifying superseded by Generate Grid (' .. who .. ')')
  end
  formGrid('race', who)
end

-- Ready, or not: the driver's own call; an admin may make it for someone (`pid`).
-- Not ready takes the car off the slot and ghosts it.
function RM_onSetReady(pid, rawData)
  local data = {}
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, d = pcall(Util.JsonDecode, rawData)
    if ok and type(d) == 'table' then data = d end
  end
  local want = data.ready ~= false
  local target = pidKey(pid)
  if data.pid ~= nil and pidKey(data.pid) ~= target then
    if not requireAuth(pid) then return end
    target = pidKey(data.pid)
  end
  local rec = target and players[target]
  if not rec or race.phase ~= 'grid' then
    broadcastState(pid)
    return
  end
  local by = target == pidKey(pid) and '' or (' (by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
  if want and rec.status == 'called' then
    race.readyUp(rec)
    local ready, total = race.readyCounts()
    print(string.format('[RaceManager] %s is ready%s: %d/%d', rec.name, by, ready, total))
    race.announceIfAllReady()
  elseif not want and rec.status == 'gridded' and race.readyCheck then
    race.callToGrid(rec, rec.gridPos)
    print(string.format('[RaceManager] %s is not ready any more%s', rec.name, by))
  end
  broadcastState()
end

-- Ready All: everyone called is placed now, staggered.
function RM_onReadyAll(pid)
  if not requireAuth(pid) then return end
  if race.phase ~= 'grid' then return end
  local called = {}
  for _, rec in pairs(players) do
    if rec.status == 'called' then called[#called + 1] = rec end
  end
  table.sort(called, function (a, b) return (a.gridPos or 0) < (b.gridPos or 0) end)
  for i, rec in ipairs(called) do race.readyUp(rec, i, #called) end
  print(string.format('[RaceManager] Ready All by %s: %d placed',
    MP.GetPlayerName(pid) or pid, #called))
  broadcastState()
end

-- Calling the grid vs placing it, from the next grid on.
function RM_onSetReadyCheck(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data or type(data.on) ~= 'boolean' then return end
  race.readyCheck = data.on
  print(string.format('[RaceManager] Ready check %s by %s',
    data.on and 'on' or 'off', MP.GetPlayerName(pid) or pid))
  broadcastState()
end

-- How the grid is filled; locked once a session is under way.
function RM_onSetGridMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'quali' and mode ~= 'reverse' and mode ~= 'random'
     and mode ~= 'custom' and mode ~= 'heats'
     and mode ~= 'points' and mode ~= 'pointsrev' then
    return
  end
  -- Heats order needs a heat program, or it silently falls back to quali.
  if mode == 'heats' and race.heatCount == 0 then
    MP.SendChatMessage(pid, '[RaceManager] Heats order needs a heat program: set the '
      .. 'number of heats and draw the field first.')
    broadcastState()
    return
  end
  race.gridMode = mode
  broadcastState()
  print('[RaceManager] Grid mode set to "' .. mode .. '" by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Custom grid: pin one driver to one slot, unpinning whoever held it.
function RM_onSetDriverGrid(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
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

-- A client reports the loaded track's start positions (count, for the field-size
-- warning; coordinates, to police the hold). Coordinates only while nothing is
-- under way: a client must not move the slots the hold is judged against.
function RM_onStartPositionCount(pid, rawData)
  local n = decodeNumber(rawData, 'count')
  if not n then return end
  n = math.floor(n)
  if n < 0 then n = 0 end

  if not sessionUnderWay() and race.phase ~= 'grid'
     and type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then
      if type(data.positions) == 'table' then
        race.startPositions = sanitizeCheckpoints(data.positions) or {}
        -- gridOffLine and the joker gate count ride along, but ONLY when no
        -- layout came through this server: every client sends this, and a
        -- loaded layout is the authority on its own grid and joker route.
        -- (A spectator's empty editor once zeroed the joker count.)
        if race.layout == nil then
          race.gridOffLine = data.gridOffLine == true
        end
        local jg = race.layout == nil and tonumber(data.jokerGates) or nil
        if jg then
          race.jokerGates = math.max(math.floor(jg), 0)
          if race.jokerGates == 0 and race.jokerEnabled then
            race.jokerEnabled = false
            MP.SendChatMessage(-1, '[RaceManager] Joker lap switched off: '
              .. 'the Joker Route was cleared.')
            print('[RaceManager] Joker lap auto-disabled: the joker route was cleared')
            -- Broadcast here: the tail below returns early when the slot count
            -- did not change.
            broadcastState()
          end
        end
      elseif n ~= #race.startPositions then
        -- A count that no longer matches the coordinates we hold, with none
        -- sent (an older client): drop them rather than police a moved grid.
        race.startPositions = {}
      end
    end
  end

  if n == race.startSlots then return end
  race.startSlots = n
  broadcastState()
end

-- A driver pitted. The stop is the client's; this is the record, for the
-- results. A stall is a repair, not a regulation.
function RM_onPitStop(pid, rawData)
  pid = pidKey(pid)
  if not pid then return end
  local rec = players[pid]
  if not rec then return end
  if not sessionRunning() then return end
  if not onTrack(rec) then return end
  local stall = 0
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then stall = tonumber(data.stall) or 0 end
  end
  rec.pitStops = (rec.pitStops or 0) + 1
  print(string.format('[RaceManager] %s pitted (stall %s) on lap %s at race time %.1fs: stop #%d',
    rec.name, tostring(stall), tostring(rec.currentLap or '?'), race.time, rec.pitStops))
  broadcastState()
end

-- Circuit or point-to-point sprint; locked once a session is under way.
function RM_onSetPointToPoint(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  race.pointToPoint = data.enabled == true or data.enabled == 1
  race.dragStrip    = race.pointToPoint and data.drag == true
  -- A sprint turns the pace lap off, and says so (it would otherwise read
  -- ENABLED while doing nothing).
  if race.pointToPoint and race.paceLap then
    race.paceLap = false
    MP.SendChatMessage(-1, '[RaceManager] Pace lap switched off: a sprint stage '
      .. 'is driven once and has no lap to form up on.')
    print('[RaceManager] Pace lap auto-disabled: the track is point-to-point')
  end
  broadcastState()
  print('[RaceManager] Track mode: '
    .. (race.dragStrip and 'DRAG STRIP' or race.pointToPoint and 'POINT TO POINT' or 'circuit')
    .. ' (by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
end

-- ---------------------------------------------------------------------------
-- Grid hold enforcement
-- ---------------------------------------------------------------------------
-- The server owns the hold but cannot apply one: clients freeze their own cars,
-- and every held car reports where it is so one off its slot is pulled back,
-- even when the client guard does not run.
-- Where a slot IS, or nil when the grid's coordinates were never reported (the
-- client guard then enforces alone: police nothing rather than the wrong grid).
local function slotPosition(rec)
  if not rec or not rec.gridPos then return nil end
  local list = race.startPositions
  if type(list) ~= 'table' then return nil end
  -- Only against the grid the field was gridded on (counts must match).
  if #list ~= race.startSlots then return nil end
  return list[rec.gridPos]
end

-- Is this a moment when cars are meant to be standing still on the grid?
local function holdInForce()
  return race.phase == 'grid' or race.phase == 'countdown'
end

-- A held client reported its position: pull it back if off the slot.
function RM_onHoldPos(pid, rawData)
  pid = pidKey(pid)
  if not pid then return end
  if not holdInForce() then return end
  local rec = players[pid]
  if not rec or rec.status ~= 'gridded' then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end

  local slot = slotPosition(rec)
  if not slot then return end

  -- HORIZONTAL distance: the slot height is the drop point, and a 3D test pinned
  -- a settling car in the air being reset.
  local dx, dy = x - slot.x, y - slot.y
  local drift = math.sqrt(dx * dx + dy * dy)
  if drift <= CFG.holdTolerance then
    rec.holdWarned = nil
    return
  end

  -- Rate-limited per driver on the server clock too (a car being shoved).
  local now = race.time
  if rec.holdCorrectedAt and (now - rec.holdCorrectedAt) < CFG.holdCorrectEvery then
    return
  end
  rec.holdCorrectedAt = now
  rec.holdCorrections = (rec.holdCorrections or 0) + 1

  MP.TriggerClientEvent(pid, 'RM_HoldCorrect', Util.JsonEncode({
    x = slot.x, y = slot.y, z = slot.z, hx = slot.hx, hy = slot.hy,
    reason = string.format('%.2fm off slot %d', drift, rec.gridPos),
  }))
  print(string.format(
    '[RaceManager] HOLD violation: %s was %.2fm off grid slot %d during %s '
    .. '(tolerance %.2fm): pulled back, correction #%d',
    rec.name, drift, rec.gridPos, race.phase, CFG.holdTolerance, rec.holdCorrections))
end

-- Display aliases: admin-only (nothing could stop a self-service name being
-- reset). Only rec.alias is written, never used as a key, and EVERY exit
-- path reports back.
local function aliasResult(pid, ok, msg)
  MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
    success = ok and true or false,
    message = msg,
  }))
  print('[RaceManager] Alias: ' .. msg)
end

-- Apply or clear (blank) a display name: THE single place, so the cup roster
-- is always told. Returns ok, message.
local function applyAlias(rec, raw)
  raw = tostring(raw or '')
  if raw:gsub('%s', '') == '' then
    if not rec.alias then
      return true, rec.name .. ' has no display name to clear.'
    end
    local was = rec.alias
    rec.alias = nil
    rememberIdentity(rec)
    -- The roster entry is not deleted: its points wait to be bound again.
    if rosterUnbind then rosterUnbind(rec.id) end
    return true, 'Display name cleared for ' .. rec.name .. ' (was "' .. was .. '").'
  end

  local clean, why = sanitizeAlias(raw)
  if not clean then return false, 'Name rejected: ' .. why .. '.' end
  if aliasInUse(clean, rec.id) then
    return false, 'Name rejected: "' .. clean .. '" is already in use.'
  end

  rec.alias = clean
  -- Into the registry: the record is rebuilt next session.
  rememberIdentity(rec)
  -- And the roster, which outlives the process and rebinds a returning driver's
  -- points by name.
  if rosterRemember then rosterRemember(rec) end
  return true, 'Display name "' .. clean .. '" set for ' .. rec.name .. '.'
end

function RM_onSetAlias(pid, rawData)
  -- Not silently: the client may believe it is admin after a server restart.
  if not isAuthenticated(pid) then
    print('[RaceManager] Ignored alias command from unauthenticated player ' .. tostring(pid))
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = false }))
    aliasResult(pid, false, 'Not logged in as an admin on this server: log in again.')
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

  local ok, msg = applyAlias(rec, decodeString(rawData, 'alias') or '')
  if ok then
    broadcastState()
    -- And the roster view, which only the cup broadcast carries.
    if broadcastCupState then broadcastCupState() end
  end
  aliasResult(pid, ok, msg)
end

-- Race length: laps, a clock, or both (endurance); 0 seconds puts a race on
-- laps. Refused mid-session: that would be changing a result.
function RM_onSetRaceLimits(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local laps = tonumber(data.laps)
  local secs = tonumber(data.seconds)
  local mode = tostring(data.mode or '')
  if mode == 'laps' or mode == 'timed' or mode == 'endurance' then
    race.raceMode = mode
  elseif secs then
    -- No mode: a pre-endurance client, read by its numbers.
    race.raceMode = (tonumber(secs) or 0) > 0 and 'timed' or 'laps'
  end
  if laps then
    laps = math.floor(laps)
    if laps < 1 then laps = 1 elseif laps > CFG.maxTotalLaps then laps = CFG.maxTotalLaps end
    race.totalLaps = laps
  end
  if secs then
    secs = math.floor(secs)
    if secs < 0 then secs = 0 elseif secs > CFG.maxRaceTime then secs = CFG.maxRaceTime end
    race.raceTimeLimit = secs
  end
  -- The invariant, enforced here: a lap race carries no clock.
  if race.raceMode == 'laps' then
    race.raceTimeLimit = 0
  elseif race.raceTimeLimit <= 0 then
    -- A clock mode with no clock is a lap race.
    race.raceMode = 'laps'
  end
  broadcastState()
  print(string.format('[RaceManager] Race length set by %s: %s',
    MP.GetPlayerName(pid) or pid, raceLengthLabel()))
end

function RM_onSetTotalLaps(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local n = decodeNumber(rawData, 'laps')
  if not n then return end
  n = math.floor(n)
  if n < 1 then n = 1 elseif n > CFG.maxTotalLaps then n = CFG.maxTotalLaps end
  race.totalLaps = n
  broadcastState()
  print('[RaceManager] Total laps set to ' .. n .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Module 1: vehicle reset ruleset
-- ---------------------------------------------------------------------------
-- Resets per driver per session: negative unlimited, 0 none, N allowed.
-- Locked once under way.
function RM_onSetMaxResets(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local n = decodeNumber(rawData, 'maxResets')
  if not n then return end
  n = math.floor(n)
  if n < 0 then n = CFG.unlimitedResets elseif n > CFG.maxResetLimit then n = CFG.maxResetLimit end
  race.maxResets = n
  broadcastState()
  print('[RaceManager] Max vehicle resets set to '
    .. (n < 0 and 'unlimited' or tostring(n)) .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- What a legal reset does: repair in place, or respawn at the last checkpoint
-- (client-side; the server holds the switch).
function RM_onSetResetMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'inplace' and mode ~= 'checkpoint' then return end
  race.resetMode = mode
  broadcastState()
  print('[RaceManager] Reset mode set to "' .. mode .. '" by ' .. (MP.GetPlayerName(pid) or pid))
end

-- A client spent a reset; the server keeps the tally for the table and results.
function RM_onVehicleReset(pid)
  local rec = players[pid]
  if not rec then return end
  if not sessionUnderWay() then return end
  -- Only drivers still in the session spend allowance.
  if not onTrack(rec) and rec.status ~= 'gridded' then return end
  -- Never past the limit: an over-allowance report counts as blocked.
  if race.maxResets >= 0 and (rec.resets or 0) >= race.maxResets then
    RM_onResetDenied(pid)
    return
  end
  rec.resets = (rec.resets or 0) + 1
  print(string.format('[RaceManager] %s used reset %d/%s',
    rec.name, rec.resets, race.maxResets < 0 and '∞' or tostring(race.maxResets)))
  broadcastState()
end

-- A refused reset: the client blocked it; this only counts the attempt.
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
-- Reset ghosting
-- ---------------------------------------------------------------------------
-- A client ghosted itself after a reset. The duration is CLAMPED, never trusted.
function RM_onGhostStart(pid, rawData)
  pid = pidKey(pid)
  if not pid then return end
  if not CFG.ghostOnReset then return end
  local rec = players[pid]
  if not rec then return end
  if not sessionUnderWay() then return end
  if not onTrack(rec) and rec.status ~= 'gridded' then return end

  local requested = CFG.ghostMinSeconds
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' and tonumber(data.duration) then
      requested = tonumber(data.duration)
    end
  end
  if requested < CFG.ghostMinSeconds then requested = CFG.ghostMinSeconds end
  if requested > CFG.ghostMaxSeconds then requested = CFG.ghostMaxSeconds end

  -- A repeat reset restarts the timer rather than stacking a second ghost.
  local repeated = ghosts[pid] ~= nil
  ghosts[pid] = { startedAt = race.time, duration = requested }
  broadcastGhost(pid, ghosts[pid])
  rec.ghosts = (rec.ghosts or 0) + 1
  -- The audit line: position, lap and distance at the moment it went intangible,
  -- from telemetry already reported.
  print(string.format(
    '[RaceManager] %s GHOSTED %.1fs at race time %.1fs: P%s, lap %s, %s to next gate%s (ghost #%d this session)',
    rec.name, requested, race.time,
    tostring(rec.position or '?'), tostring(rec.currentLap or '?'),
    rec.distNext and string.format('%.0fm', rec.distNext) or 'distance unknown',
    repeated and ', TIMER RESTARTED' or '', rec.ghosts))
  broadcastState()
end

-- The owning client reports its space clear: only it can know, so it is relayed.
function RM_onGhostEnd(pid)
  pid = pidKey(pid)
  if not pid then return end
  if clearGhost(pid, 'client reported clear') then broadcastState() end
end

-- A ghost blocked by an occupied space for a long time. A WARNING ONLY: forcing
-- it off is what welds two cars.
function RM_onGhostBlocked(pid, rawData)
  pid = pidKey(pid)
  if not pid then return end
  local rec = players[pid]
  if not rec or not ghosts[pid] then return end
  local seconds = 0
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then seconds = tonumber(data.seconds) or 0 end
  end
  print(string.format(
    '[RaceManager] %s is still ghosted: another car has been occupying its space '
    .. 'for %.1fs (race time %.1fs). Not forced: restoring collision on '
    .. 'overlapping cars would weld them together.', rec.name, seconds, race.time))
end

-- ---------------------------------------------------------------------------
-- Module 2: rallycross joker lap
-- ---------------------------------------------------------------------------
-- Arm the joker requirement (the route ships with the layout). Locked mid-race.
function RM_onSetJokerEnabled(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local want = data.enabled == true or data.enabled == 1
  -- A joker lap with no joker route disqualifies the whole field at the flag:
  -- refused out loud.
  if want and race.jokerGates == 0 then
    MP.SendChatMessage(pid, '[RaceManager] This track has no Joker Route. '
      .. 'Place joker gates in the editor first: arming the joker lap without '
      .. 'them would disqualify everyone who finishes.')
    print('[RaceManager] Joker lap refused: the loaded track has no joker gates')
    broadcastState()
    return
  end
  race.jokerEnabled = want
  broadcastState()
  print('[RaceManager] Joker lap ' .. (race.jokerEnabled and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- The pace lap for the next race. Idle-locked (it changes sessionLapTarget).
-- Refused out loud on a sprint stage, where there is no lap to form up on.
function RM_onSetPaceLap(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local want = data.enabled == true or data.enabled == 1
  if want and race.pointToPoint then
    MP.SendChatMessage(pid, '[RaceManager] This track is a sprint stage, which is '
      .. 'driven once from the first gate to the last. There is no lap to form '
      .. 'up on, so a pace lap cannot be run on it.')
    print('[RaceManager] Pace lap refused: the loaded track is point-to-point')
    broadcastState()
    return
  end
  race.paceLap = want
  broadcastState()
  print('[RaceManager] Pace lap ' .. (race.paceLap and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- The free pass rule. NOT idle-locked: it changes nothing until a yellow, and a
-- marshal deciding mid-race is exactly what the switch is for.
function RM_onSetLuckyDog(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  race.luckyDog = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Lucky dog ' .. (race.luckyDog and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- A client completed the joker route (it enforced lap 1 and once); the server
-- records it and rules at the flag.
function RM_onJokerLap(pid, rawData)
  -- Race only: no joker in qualifying.
  if race.phase ~= 'racing' or isQualiSession() then return end
  local rec = players[pidKey(pid) or -1]
  if not rec or rec.status ~= 'racing' then return end
  rec.jokerTaken = (rec.jokerTaken or 0) + 1
  local lap = decodeNumber(rawData, 'lap')
  -- The fallback must agree with the client, which reports the RACING lap
  -- (currentLap counts crossings, one more behind the pace car).
  if rec.jokerLap == nil then
    rec.jokerLap = lap and math.floor(lap)
      or math.max(1, (rec.currentLap or 1) - (paceLapArmed() and 1 or 0))
  end
  print(string.format('[RaceManager] %s took the joker route on lap %s (total %d)',
    rec.name, tostring(rec.jokerLap), rec.jokerTaken))
  broadcastState()
end

-- Grid audit (Module 4): REPORTS ONLY. The live check already removed illegal
-- cars from non-admins; deleting a car seconds before GO does more harm than
-- one wrong setup. Shared by both start procedures.
local function reportGridAudit(pid)
  local bad = garageAudit and garageAudit() or {}
  if #bad == 0 then return end
  local names = {}
  for i, b in ipairs(bad) do
    names[i] = b.name .. (b.admin and ' (admin)' or '') .. ' [' .. b.label .. ']'
  end
  local line = 'Starting with ' .. #bad .. ' car(s) not on the Garage List: '
    .. table.concat(names, ', ')
  print('[RaceManager] ' .. line)
  MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
    added = false, message = line,
  }))
end

function RM_onStartCountdown(pid)
  if not requireAuth(pid) then return end
  if race.phase ~= 'grid' then return end
  if not race.dropUnready() then
    MP.SendChatMessage(pid, '[RaceManager] Nobody is ready yet. Wait for Ready, '
      .. 'or press Ready All to place everyone.')
    return
  end
  reportGridAudit(pid)
  race.phase = 'countdown'
  countdownValue = CFG.countdownFrom
  broadcastState()
  broadcastCountdown(countdownValue)
  MP.CreateEventTimer('RM_CountdownTick', 1000)
  print('[RaceManager] Countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

-- GO: THE ONE PLACE THE FIELD IS RELEASED, for the lights (RM_CountdownTick) and
-- the pace car (RM_onStartRace) alike, so no second path forgets a reset.
-- `pacing` changes only the flag and whether the green has fallen; the pace lap
-- is an out lap (outLapOwed).
local function releaseField(pacing)
  race.phase = runningStatus()   -- 'qualifying' or 'racing'
  -- A pace lap runs under yellow; every other session starts green.
  race.pacing = pacing == true
  race.flag   = race.pacing and 'yellow' or 'green'
  -- The paceArmAt latch starts closed: the field is at the line.
  race.paceArmed = false
  race.greenZone = nil
  if race.pacing then race.drawGreenZone() end
  -- Nothing carries a caution into a new session.
  race.caution      = false
  race.cautionPending = false
  race.restartPending = false
  race.cautionLucky = nil
  race.cautionLap   = nil
  race.cautionLaps  = 0
  race.cautionSeq   = 0
  race.cautionCount = 0
  thawOrder()
  race.time = 0.0
  -- The green is now, or stamped when it falls after a pace lap.
  race.greenAt = 0.0
  race.endsAt, race.endReason = nil, nil
  race.qualiTime = 0.0
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil
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
      rec.dnfPos     = nil
      rec.heldPos    = nil
      if isQualiSession() then
        rec.qualiBest = nil
        rec.qualiLaps = 0
      end
      rec.outLap     = outLapOwed()
      rec.splits   = nil
      rec.splitLap = nil
      rec.splitCp  = nil
      rec.gap, rec.intv = nil, nil
      progress.clear(rec)
    end
  end
  -- Recorded for the results file, written after the rule has moved on.
  if isQualiSession() then race.qualiOutLapRun = outLapOwed() end
  if not isQualiSession() then
    race.raceOutLapRun  = outLapOwed()
    race.racePaceLapRun = race.pacing
  end
  broadcastState()
  -- The pace lap gets the first word: it is an instruction (both speed units:
  -- drivers on both sides of the Atlantic).
  if race.pacing then
    notifyField('flag', 'PACE LAP', 'Maintain position and limit '
      .. 'your speed to 50 MPH or 80 KMH. No overtaking. The GREEN FLAG can fall '
      .. 'anywhere on the run to the start/finish line: be ready.', 'yellow')
  elseif outLapOwed() and isQualiSession() then
    notifyField('flag', 'GO! Your first lap is an OUT LAP', 'It is '
      .. 'not timed and does not count. Timing starts as you cross the line.', 'green')
  elseif outLapOwed() then
    -- No field notice for a race's out lap (it describes the results table, not
    -- when to go). Restore this notifyField and the client's matching arm
    -- together to bring it back. Logged, so an owed lap can be traced.
    print('[RaceManager] Out lap owed: sessionKind=' .. tostring(race.sessionKind)
      .. ', gridOffLine=' .. tostring(race.gridOffLine))
  end
  local target = sessionLapTarget()
  -- The target counts crossings, so qualifying logs its two halves.
  local lapNote
  if isQualiSession() then
    lapNote = (race.qualiLapLimit > 0 and (race.qualiLapLimit .. ' timed lap'
      .. (race.qualiLapLimit == 1 and '' or 's')) or 'unlimited timed laps')
      .. (outLapOwed() and ' + out lap' or '')
  else
    lapNote = (target and (target .. ' laps') or 'unlimited laps')
      .. (outLapOwed() and ' (incl. out lap)' or '')
  end
  print('[RaceManager] ' .. (race.pacing and 'PACE LAP!' or 'GO!')
    .. ' (' .. (isQualiSession() and 'qualifying' or 'race') .. ', '
    .. lapNote .. ')'
    .. (race.jokerEnabled and not isQualiSession() and ': JOKER LAP REQUIRED' or '')
    .. (race.maxResets >= 0 and (': resets limited to ' .. race.maxResets) or ''))
end

-- THE GREEN FLAG ending a pace lap, one path for the manual green (RM_onSetFlag)
-- and the automatic one. It starts the RACE clock a timed race runs to.
local function dropGreenFlag(why)
  if not race.pacing then return false end
  race.pacing  = false
  race.flag    = 'green'
  race.greenAt = race.time
  notifyField('flag', 'GREEN FLAG - GO!', 'The pace lap is over '
    .. 'and the race is on.', 'green')
  print(string.format('[RaceManager] GREEN FLAG at %.1fs: %s', race.time,
    why or 'pace lap complete'))
  broadcastState()
  return true
end

-- The final sector's straight-line length (last checkpoint, or its nearest
-- branch gate, to the line). nil when the server holds no route.
function race.finalSectorLength()
  local cps = type(race.layout) == 'table' and race.layout.checkpoints
  if type(cps) ~= 'table' or #cps < 2 then return nil end
  local n, sf = #cps, cps[#cps]
  local function dist(g)
    local dx, dy, dz = (g.x or 0) - sf.x, (g.y or 0) - sf.y, (g.z or 0) - sf.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  local best = dist(cps[n - 1])
  for _, b in ipairs(race.branches or {}) do
    if tonumber(b.slot) == n - 1 and dist(b) < best then best = dist(b) end
  end
  return best
end

-- Where the green falls: a fresh random distance before the line per pace lap
-- and restart, so it cannot be learned. Capped inside the final sector.
function race.drawGreenZone()
  race.greenReady = false
  local lo, hi = CFG.paceGreenNear, CFG.paceGreenFar
  local sector = race.slotCount >= 2 and race.finalSectorLength() or nil
  if sector then hi = math.min(hi, sector * 0.9) end
  if not sector or hi <= lo then
    race.greenZone = lo
  else
      -- Seeded: Lua 5.3 starts every boot on the same sequence.
    if not randomSeeded then
      math.randomseed(os.time() + os.clock() * 1000)
      randomSeeded = true
    end
    race.greenZone = lo + math.random() * (hi - lo)
  end
  print(string.format('[RaceManager] Green zone: %.0fm before the line (range %.0f-%.0fm)',
    race.greenZone, lo, math.max(lo, hi)))
  return race.greenZone
end

-- The run to the green (pace lap and restart), the leader already on the final
-- sector: GET READY once within paceReadyAt, true at the drawn green point. On a
-- short final sector the call comes at its start (a back straight can pass near
-- the line mid-lap).
function race.greenApproach(leader)
  if not race.greenReady and leader.distNext <= CFG.paceReadyAt then
    race.greenReady = true
    print(string.format('[RaceManager] GET READY: %s is %.0fm from the line',
      leader.name, leader.distNext))
    broadcastState()
  end
  return leader.distNext <= (race.greenZone or CFG.paceGreenNear)
end

-- Who leads the pace lap: raceOrderLess over the drivers still ON it (owing
-- the crossing that starts lap 1). THE CAR THAT STARTED P1 runs the start
-- while it is on the pace lap. nil when nobody is left on it.
local function paceLeader()
  local best, pole = nil, nil
  for _, rec in pairs(players) do
    -- Not gated on a reported distance: before the first telemetry nobody has
    -- one, and "nobody found" would drop an immediate green.
    if onTrack(rec) and rec.outLap then
      if rec.gridPos == 1 then pole = rec end
      if not best or raceOrderLess(rec, best) then best = rec end
    end
  end
  return pole or best
end

-- The pace lap, one tick at a time. The field STARTS at the line, so the green
-- needs a latch: armed once the leader is genuinely away, then fired on the way
-- back. leader.distNext is METERS TO THE LINE on an out lap only (see
-- reportProgress on the client before changing either side).
local function paceLapWatch()
  -- A red flag holds everything; the admin's manual green ends the pace lap.
  if race.flag == 'red' then return end
  local leader = paceLeader()
  if not leader then
    -- Nobody on the pace lap: nothing can hold the green up any more.
    dropGreenFlag('no driver left on the pace lap')
    return
  end
  -- No telemetry yet: wait.
  if not leader.distNext then return end
  if race.slotCount >= 2 then
    -- The final sector opens the run in, as for a restart.
    if (leader.cpCleared or 0) < race.slotCount - 1 then return end
    if not race.paceArmed then
      race.paceArmed = true
      print(string.format('[RaceManager] Pace lap on its final sector: %s leads, %.0fm from the line',
        leader.name, leader.distNext))
    end
    if race.greenApproach(leader) then
      dropGreenFlag(string.format('%s is %.1fm from the line', leader.name, leader.distNext))
    end
    return
  else
    -- No route on the server: the distance latch and the fixed green point.
    if not race.paceArmed then
      if leader.distNext > CFG.paceArmAt then
        race.paceArmed = true
        print(string.format('[RaceManager] Pace lap under way: %s leads, %.0fm from the line',
          leader.name, leader.distNext))
      end
      return
    end
  end
  if leader.distNext <= CFG.paceGreenAt then
    dropGreenFlag(string.format('%s is %.1fm from the line', leader.name, leader.distNext))
  end
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
  -- GO: one release for both kinds of session.
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(0)
  releaseField(false)
end

-- ---------------------------------------------------------------------------
-- Module 6: heats and transfers
-- ---------------------------------------------------------------------------
-- Heat count and transfers; idle-locked. 0 ends the program and forgets the
-- draw (the way out of a half-configured night).
function RM_onSetHeats(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local count    = math.floor(tonumber(data.count) or 0)
  local transfer = math.floor(tonumber(data.transfer) or 0)
  -- Absent, not zero, from an older client.
  local laps     = data.laps ~= nil and math.floor(tonumber(data.laps) or 0) or race.heatLaps
  if count < 0 then count = 0 elseif count > CFG.maxHeats then count = CFG.maxHeats end
  if transfer < 0 then transfer = 0 end
  -- 0 means the race's distance, so it is not clamped away.
  if laps < 0 then laps = 0 elseif laps > CFG.maxTotalLaps then laps = CFG.maxTotalLaps end
  race.heatLaps = laps
  -- Not clamped to the heat size: the field is unknown until the draw.
  race.heatCount    = count
  race.heatTransfer = transfer
  if count == 0 then
    -- Off: a stale heatCurrent would grid nobody.
    race.heatCurrent = 0
    race.heatsDrawn  = false
    race.heatLaps    = 0
    for _, rec in pairs(players) do
      rec.heat, rec.heatPos, rec.transferred = nil, nil, nil
      rememberIdentity(rec)
    end
    if race.gridMode == 'heats' then race.gridMode = 'quali' end
  end
  broadcastState()
  print(string.format('[RaceManager] Heat program: %s (by %s)',
    count == 0 and 'off' or (count .. ' heats, top ' .. transfer .. ' transfer, '
      .. (laps > 0 and (laps .. ' laps each') or 'race distance')),
    MP.GetPlayerName(pid) or pid))
end

-- Split the field into heats by SERPENTINE (1..N, then back N..1), so every heat
-- gets a quick driver and a slow one and the transfers are comparable. Unseeded
-- drivers go last, in join order.
function RM_onDrawHeats(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] Cannot redraw the heats while a session is under way.')
    return
  end
  if race.heatCount < 2 then
    MP.SendChatMessage(pid, '[RaceManager] Set the number of heats to 2 or more first.')
    return
  end
  -- The whole field: the draw creates the heats (isEntrant would filter).
  local field = {}
  for _, rec in pairs(players) do
    if not rec.spectating then field[#field + 1] = rec end
  end
  if #field == 0 then
    MP.SendChatMessage(pid, '[RaceManager] Nobody to draw: every connected driver is sitting out.')
    return
  end
  -- What the draw is seeded on; the serpentine is the same either way.
  local mode = race.heatDraw or 'quali'
  local seeded = 0          -- how many drivers the seed actually knows about
  if mode == 'random' then
    shuffle(field)
    seeded = #field
  elseif mode == 'points' then
    -- Championship order, leader first, read without enrolling anybody.
    local pts = {}
    for _, rec in ipairs(field) do
      local p = cupSeasonPoints and cupSeasonPoints(rec) or nil
      pts[rec.id] = p
      if p then seeded = seeded + 1 end
    end
    if seeded == 0 then
      -- Refused: with no points it would quietly become join order.
      MP.SendChatMessage(pid, '[RaceManager] Nobody in the field has any '
        .. 'championship points, so there is no order to seed from. Run a cup '
        .. 'round first, or draw on qualifying times or at random.')
      return
    end
    table.sort(field, function (a, b)
      local pa, pb = pts[a.id], pts[b.id]
      if pa and pb then
        if pa ~= pb then return pa > pb end
      elseif pa ~= pb then
        return pa ~= nil
      end
      return a.id < b.id
    end)
  else
    for _, rec in ipairs(field) do if rec.qualiBest then seeded = seeded + 1 end end
    table.sort(field, function (a, b)
      local ta, tb = a.qualiBest, b.qualiBest
      if ta and tb then
        if ta ~= tb then return ta < tb end
      elseif ta ~= tb then
        return ta ~= nil
      end
      return a.id < b.id
    end)
    -- Said out loud when no qualifying times exist: the draw is join order.
    if seeded == 0 then
      MP.SendChatMessage(pid, '[RaceManager] Nobody set a qualifying time, so '
        .. 'this draw is in join order. Draw at random or on championship '
        .. 'points if you want a real seeding.')
    end
  end
  local n = race.heatCount
  for i, rec in ipairs(field) do
    -- The serpentine as arithmetic over each pass of 2n drivers.
    local k = (i - 1) % (2 * n)
    rec.heat = (k < n) and (k + 1) or (2 * n - k)
    rec.heatPos     = nil
    rec.transferred = nil
    rememberIdentity(rec)
  end
  race.heatsDrawn  = true
  race.heatCurrent = 1
  -- Say what was drawn, per heat.
  local sizes = {}
  for h = 1, n do
    local c = 0
    for _, rec in ipairs(field) do if rec.heat == h then c = c + 1 end end
    sizes[#sizes + 1] = 'H' .. h .. ':' .. c
  end
  local SEED_WORDS = {
    quali  = 'seeded on qualifying times',
    random = 'drawn at random',
    points = 'seeded on championship points',
  }
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] HEATS DRAWN: %d drivers into %d heats (%s), %s. Top %d from '
    .. 'each transfer to the feature.', #field, n, table.concat(sizes, ' '),
    SEED_WORDS[mode] or SEED_WORDS.quali, race.heatTransfer))
  print(string.format('[RaceManager] Heats drawn by %s: %d drivers, %d heats (%s)',
    MP.GetPlayerName(pid) or pid, #field, n, table.concat(sizes, ' ')))
  broadcastState()
end

-- What the heat draw is seeded on; idle-locked. Changing it does not redraw.
function RM_onSetHeatDraw(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local mode = tostring(data.mode or '')
  if mode ~= 'quali' and mode ~= 'random' and mode ~= 'points' then return end
  race.heatDraw = mode
  broadcastState()
  print(string.format('[RaceManager] Heat draw seeded on %s (by %s)',
    mode, MP.GetPlayerName(pid) or pid))
end

-- Which heat is set up next (0: the feature): what isEntrant grids.
function RM_onSetHeatCurrent(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local heat = math.floor(tonumber(data.heat) or 0)
  if heat < 0 or heat > race.heatCount then return end
  race.heatCurrent = heat
  broadcastState()
  print(string.format('[RaceManager] Next session: %s (by %s)',
    heat == 0 and 'the FEATURE' or ('heat ' .. heat), MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- The caution and the restart
-- ---------------------------------------------------------------------------
-- Who leads under caution: the top of the FROZEN board among cars still
-- circulating, the car the restart waits on.
local function cautionLeader()
  local best = nil
  for _, rec in pairs(players) do
    if onTrack(rec) then
      if not best or raceOrderLess(rec, best) then best = rec end
    end
  end
  return best
end

-- THE FREE PASS: the highest-placed car a lap or more down (not the furthest
-- back, which would always be the same slowest car) gets one lap and the TAIL of
-- the lead lap. The client is told (RM_LapCredit): RM_onProgress drops telemetry
-- whose lap disagrees with the server's.
local function awardLuckyDog(why)
  if not race.luckyDog or race.cautionLucky or not race.caution then return nil end
  local order = raceClassification()
  for _, rec in ipairs(order) do
    if onTrack(rec) and (rec.cautionDown or 0) >= 1 then
      race.cautionSeq  = race.cautionSeq + 1
      rec.cautionPos   = race.cautionSeq
      rec.cautionDown  = rec.cautionDown - 1
      rec.currentLap   = (rec.currentLap or 0) + 1
      race.cautionLucky = rec.id
      -- The lap moved: old checkpoint telemetry must not rank them.
      progress.clear(rec)
      MP.TriggerClientEvent(rec.id, 'RM_LapCredit', Util.JsonEncode({
        lap = rec.currentLap, reason = 'luckydog',
      }))
      MP.SendChatMessage(-1, string.format(
        '[RaceManager] FREE PASS: %s takes their lap back and restarts at the '
        .. 'tail of the lead lap.', displayName(rec)))
      print(string.format('[RaceManager] Lucky dog: %s now on lap %d (%s)',
        rec.name, rec.currentLap, why or 'field locked'))
      return rec
    end
  end
  return nil
end

-- Lock one driver's caution place at their own crossing, ONCE (the field keeps
-- crossing under yellow). `completed` is the lap just finished. The free pass is
-- awarded when the last car locks, so the board shows it before the green.
local function lockCaution(rec, completed)
  if not race.caution or rec.cautionPos then return end
  local down = (race.cautionLap or completed) - completed
  if down < 0 then down = 0 end
  race.cautionSeq = race.cautionSeq + 1
  rec.cautionPos  = race.cautionSeq
  rec.cautionDown = down
  for _, other in pairs(players) do
    if onTrack(other) and not other.cautionPos then return end
  end
  awardLuckyDog('field locked')
end

-- End the caution: one path for the Green button and Restart.
local function restartRace(why)
  if not race.caution then return false end
  -- The fallback award: a car that never crossed again means the field never
  -- fully locked, and the green must not cancel the pass.
  awardLuckyDog('restart called before the field was fully locked')
  race.caution        = false
  race.cautionPending = false
  race.restartPending = false
  race.flag           = 'green'
  thawOrder()
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] GREEN FLAG - RESTART! Racing resumes after %d lap%s under caution.',
    race.cautionLaps, race.cautionLaps == 1 and '' or 's'))
  print(string.format('[RaceManager] RESTART at %.1fs after %d caution lap(s): %s',
    race.time, race.cautionLaps, why or 'called by an admin'))
  broadcastState()
  return true
end

-- The restart waiting on the leader, gated on them being on the LAST leg (a
-- restart called just past the line would fire at once). With slotCount 0 (an
-- unsaved route) the leader's crossing triggers it instead, in RM_onLap.
local function restartWatch()
  -- A red flag holds everything.
  if race.flag == 'red' then return end
  if race.slotCount <= 0 then return end
  local leader = cautionLeader()
  if not leader or not leader.distNext then return end
  if (leader.cpCleared or 0) < race.slotCount - 1 then return end
  if race.greenApproach(leader) then
    restartRace(string.format('%s is %.1fm from the line', leader.name, leader.distNext))
  end
end

-- A full-course yellow, during a race only.
function RM_onCaution(pid)
  if not requireAuth(pid) then return end
  if not sessionRunning() then
    MP.SendChatMessage(pid, '[RaceManager] No race is running, so there is nothing to neutralise.')
    return
  end
  -- Qualifying runs but has no order to freeze (a separate test, or it was
  -- told no session was running).
  if isQualiSession() then
    MP.SendChatMessage(pid, '[RaceManager] Qualifying has no running order to freeze: '
      .. 'drivers are on their own laps and the board is a list of best times.')
    return
  end
  -- Already under yellow on the pace lap: the green ends it.
  if race.pacing then
    MP.SendChatMessage(pid, '[RaceManager] The field is already under yellow on the '
      .. 'pace lap. The green flag is what ends it.')
    return
  end
  if race.caution or race.cautionPending then
    MP.SendChatMessage(pid, '[RaceManager] The race is already under caution. '
      .. 'Restart when the track is clear.')
    return
  end
  -- CALLED, NOT FROZEN: official when the LEADER takes the line (RM_onLap).
  race.cautionPending = true
  race.restartPending = false
  race.cautionLucky   = nil
  race.flag           = 'yellow'
  race.cautionLap     = nil
  race.cautionLaps    = 0
  race.cautionSeq     = 0
  race.cautionCount   = race.cautionCount + 1
  local who = MP.GetPlayerName(pid) or pid
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] CAUTION - FULL COURSE YELLOW: RACE BACK TO THE LINE. Positions '
    .. 'lock as you complete this lap, and the leader decides which lap that is. '
    .. 'Slow down and hold station once you are past. By %s.', tostring(who)))
  print(string.format('[RaceManager] CAUTION #%d called by %s at %.1fs: racing back to the line',
    race.cautionCount, tostring(who), race.time))
  broadcastState()
end

-- The restart is CALLED: the admin decides there is one, the leader decides
-- when (the green on the run to the line, with the field packed up).
function RM_onRestart(pid)
  if not requireAuth(pid) then return end
  if not race.caution then
    MP.SendChatMessage(pid, race.cautionPending
      and '[RaceManager] The field is still racing back to the line. The restart '
          .. 'can be called once the caution is official.'
      or  '[RaceManager] The race is not under caution, so there is nothing to restart.')
    return
  end
  if race.restartPending then
    MP.SendChatMessage(pid, '[RaceManager] A restart is already called: the green '
      .. 'falls on the run to the line. Cancel it to hold the caution.')
    return
  end
  race.restartPending = true
  race.drawGreenZone()
  local who = MP.GetPlayerName(pid) or pid
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] RESTART THIS LAP: the green flag can fall anywhere on the run '
    .. 'to the line. Close up, hold position until then. By %s.', tostring(who)))
  print(string.format('[RaceManager] Restart called by %s at %.1fs, waiting on the leader',
    tostring(who), race.time))
  broadcastState()
  -- Judged now too, for a leader already on the last leg.
  restartWatch()
end

-- Wave a called restart off. Only the call goes: the race stays neutralised and
-- the caution laps keep counting (pressing Caution again would count a second
-- yellow).
function RM_onCancelRestart(pid)
  if not requireAuth(pid) then return end
  if not race.restartPending then
    MP.SendChatMessage(pid, '[RaceManager] No restart is called, so there is nothing '
      .. 'to wave off.')
    return
  end
  race.restartPending = false
  local who = MP.GetPlayerName(pid) or pid
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] RESTART WAVED OFF: stay under caution, hold your position. '
    .. 'By %s.', tostring(who)))
  print(string.format('[RaceManager] Restart cancelled by %s at %.1fs',
    tostring(who), race.time))
  broadcastState()
end

-- Start the race BEHIND THE PACE CAR, with no countdown: the alternative to
-- Start Countdown, not a step before it. Refused unless the pace lap is armed.
function RM_onStartRace(pid)
  if not requireAuth(pid) then return end
  if race.phase ~= 'grid' then return end
  if not paceLapArmed() then
    MP.SendChatMessage(pid, '[RaceManager] Start Race runs a PACE LAP, and the '
      .. 'pace lap is not armed for this session. Use Start Countdown, or turn '
      .. 'the pace lap on in Race settings.')
    return
  end
  if not race.dropUnready() then
    MP.SendChatMessage(pid, '[RaceManager] Nobody is ready yet. Wait for Ready, '
      .. 'or press Ready All to place everyone.')
    return
  end
  reportGridAudit(pid)
  -- Hide a countdown left up by an aborted start.
  broadcastCountdown(-1)
  releaseField(true)
  print('[RaceManager] Race started behind the pace car by '
    .. (MP.GetPlayerName(pid) or pid))
end

-- End Session: in a race anyone still on track is a DNF; qualifying keeps its
-- best laps. Every car comes back either way.
function RM_onEndRace(pid)
  if not requireAuth(pid) then return end
  if race.phase == 'grid' then
    -- Before the lights: no result, just stand the field down.
    broadcastCountdown(-1)
    race.phase = 'waiting'
    for _, rec in pairs(players) do
      if rec.status == 'gridded' then rec.status = 'waiting' end
      -- Called and never placed: the ghost was only for the call.
      if rec.status == 'called' then rec.status, rec.bystander = 'waiting', nil end
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
      retireAsDnf(rec, 'DNF - Session ended')
    end
  end
  finishSession('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onResetLeaderboard(pid)
  if not requireAuth(pid) then return end
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  -- Nothing stays ghosted through a session reset: no client is left to report
  -- the space clear.
  clearAllGhosts('session reset')
  wipe(players)
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil
  race.phase = 'waiting'
  race.sessionKind = 'race'
  race.time = 0.0
  race.endsAt, race.endReason = nil, nil
  race.qualiTime = 0.0
  race.qualiOutLapRun = false
  race.racePaceLapRun = false
  -- The pace lap's CONDITION goes, the RULE stays.
  race.pacing    = false
  race.paceArmed = false
  race.greenAt   = 0.0
  race.caution      = false
  race.cautionPending = false
  race.restartPending = false
  race.cautionLucky = nil
  race.cautionLap   = nil
  race.cautionLaps  = 0
  race.cautionSeq   = 0
  race.cautionCount = 0
  thawOrder()
  -- The heat program goes with the evening (the records holding the draw are
  -- gone).
  race.heatCount    = 0
  race.heatTransfer = 0
  race.heatCurrent  = 0
  race.heatsDrawn   = false
  race.heatLaps     = 0
  race.heatDraw     = 'quali'
  if race.gridMode == 'heats' then race.gridMode = 'quali' end
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  -- Display names survive in the identity registry.
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
-- Every racing client reports a few times a second:
--   lap  -- the lap it believes it is on (a sanity check only)
--   cp   -- checkpoints cleared on the current lap (metric 2)
--   dist -- meters to the next checkpoint's center (metric 3)
-- Stored, never broadcast here: the tick pushes the order on its own cadence.
local MAX_CHECKPOINTS = 500      -- sanity clamp on a reported checkpoint count
local MAX_REPORT_DIST = 1e6      -- meters; anything beyond this is nonsense

function RM_onProgress(pid, rawData)
  if not sessionRunning() then return end
  local rec = players[pidKey(pid) or -1]
  if not onTrack(rec) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  -- A report from another lap than the server's is dropped (positions would
  -- flicker at every crossing).
  local lap = tonumber(data.lap)
  if lap and math.floor(lap) ~= rec.currentLap then return end

  -- CHECKPOINTS cleared, not gates crossed: a branch gate clears the same one.
  local cp = tonumber(data.cp)
  if cp then
    cp = math.floor(cp)
    -- Clamped to the loaded track's length, or a flat ceiling without one.
    local ceiling = race.slotCount > 0 and race.slotCount or MAX_CHECKPOINTS
    if cp < 0 then cp = 0 elseif cp > ceiling then cp = ceiling end
    -- A count that went UP is a crossing (the client reports on the next frame),
    -- so the split is stamped; one that went down is a stale packet.
    if cp > (rec.cpCleared or 0) then progress.record(rec, rec.currentLap, cp) end
    rec.cpCleared = cp
  end

  local dist = tonumber(data.dist)
  if dist and dist >= 0 and dist <= MAX_REPORT_DIST then
    rec.distNext = dist
  end
end

-- A client crossed the S/F line after every checkpoint. ONE handler for both
-- sessions. The server decides Laps Led (first report per lap number) and the
-- finish (the lap target).
function RM_onLap(pid, rawData)
  if not sessionRunning() then return end
  local rec = ensurePlayer(pid)
  if not rec or not onTrack(rec) then return end
  local quali = isQualiSession()

  -- THE LINE IS CHECKPOINT 0 OF THE LAP STARTING, stamped above every early
  -- return (a qualifying out lap leaves a split; on the terminal crossing it is
  -- the flag itself).
  progress.record(rec, (rec.currentLap or 0) + 1, 0)

  -- THE FIRST LAP: qualifying's out lap is thrown away entirely (returned below,
  -- before the terminal check, so finalLap cannot stand a driver down on it). A
  -- RACE's first lap COUNTS but sets no TIME (a standing start is a different
  -- measurement), except in a one-lap race; behind the pace car there are two
  -- crossings, so the formation lap is always the untimed one.
  local paced = paceLapArmed()
  local untimedFirstLap = false
  if not quali and (rec.currentLap or 0) <= 1
      and ((race.totalLaps or 0) > 1 or paced) then
    rec.outLap = false
    untimedFirstLap = true
    -- A formation lap is a different fact: lap 1 of the race is starting.
    MP.SendChatMessage(rec.id, paced
      and '[RaceManager] Pace lap complete: you are racing. This is lap 1.'
      or  '[RaceManager] First lap done: it counts, but it set no lap time.')
  end
  if rec.outLap and quali then
    rec.outLap = false
    progress.clear(rec)
    rec.currentLap = rec.currentLap + 1
    broadcastState()
    -- Told to that driver alone, qualifying only.
    if isQualiSession() then
      MP.SendChatMessage(rec.id,
        '[RaceManager] Out lap complete: your next lap is TIMED.')
    end
    print(string.format('[RaceManager] %s completed their out lap (not timed)', rec.name))
    return
  end

  local lapTime = decodeNumber(rawData, 'lapTime')
  -- The launch is not a lap time; the crossing still counts.
  if untimedFirstLap then lapTime = nil end
  if lapTime and lapTime > 0 then
    if not rec.raceBest or lapTime < rec.raceBest then
      rec.raceBest = lapTime
      -- The car it was set in, for the lap records.
      rec.bestCar = rec.carLabel
    end
    -- Fastest lap of the session, one comparison per lap.
    if not race.bestLapTime or lapTime < race.bestLapTime then
      race.bestLapTime = lapTime
      race.bestLapPid  = rec.id
      print(string.format('[RaceManager] FASTEST LAP: %s %.3fs', rec.name, lapTime))
    end
    -- Qualifying scores on the best lap.
    if quali and (not rec.qualiBest or lapTime < rec.qualiBest) then
      rec.qualiBest = lapTime
      print(string.format('[RaceManager] %s quali best: %.3fs (lap %d)',
        rec.name, lapTime, (rec.qualiLaps or 0) + 1))
    end
  end

  local completed = rec.currentLap
  -- Did this crossing lead the lap? First to reach this lap number, which a
  -- lapped car coming past cannot claim.
  local ledThisLap = false
  if quali then
    rec.qualiLaps = (rec.qualiLaps or 0) + 1
  elseif not lapFirsts[completed] then
    lapFirsts[completed] = pid
    rec.lapsLed = rec.lapsLed + 1
    ledThisLap = true
    -- A lap under caution counts toward the distance, counted off the LEADER's
    -- crossing, BEFORE the promotion below (the crossing that makes a caution
    -- official is not a lap under it).
    if race.caution then
      race.cautionLaps = race.cautionLaps + 1
      print(string.format('[RaceManager] Caution lap %d (leader %s on lap %d)',
        race.cautionLaps, rec.name, completed))
    end
    -- The leader makes the caution official on this lap; everyone else locks as
    -- they complete the same lap.
    if race.cautionPending then
      race.cautionPending = false
      race.caution        = true
      race.cautionLap     = completed
      race.cautionSeq     = 0
      MP.SendChatMessage(-1, string.format(
        '[RaceManager] CAUTION IS OUT on lap %d: %s leads it. Positions lock as '
        .. 'you complete this lap. Hold station once you are past the line.',
        completed, displayName(rec)))
      print(string.format('[RaceManager] Caution official on lap %d, led by %s',
        completed, rec.name))
    end
  end
  -- This driver's caution place, once.
  lockCaution(rec, completed)
  -- The restart the distance watch missed (no slotCount, or no telemetry near
  -- the line): the leader's crossing is the backstop. cautionLeader, not
  -- ledThisLap (a lapped car claims lap numbers the front has not reached). Not
  -- under red.
  if race.restartPending and race.flag ~= 'red' and rec == cautionLeader() then
    restartRace(string.format('%s took the line (distance watch did not fire)', rec.name))
  end

  -- New lap: the old lap's telemetry must not rank this driver.
  progress.clear(rec)

  -- Is this crossing the driver's last? The lap target; the expired clock (once
  -- finalLap is armed, ANY crossing, settled by arrival order at the server); or
  -- a timed race's final lap NUMBER (everyone gets that whole lap). The lap still
  -- COUNTS: its time can improve a position.
  local target = sessionLapTarget()
  local lastLap = (target and completed >= target) or race.finalLap
    or (race.lastLapNum ~= nil and completed >= race.lastLapNum)

  -- The leader's crossing after the clock ran out starts the final lap, decided
  -- after lastLap so they run the lap they just began.
  if not lastLap and ledThisLap and race.raceExpired and not race.lastLapNum then
    armRaceFinalLap(completed + 1)
  end

  if lastLap then
    -- First car home on a timed race's final lap: the checkered flag is out and
    -- every crossing is terminal (which classifies lapped cars).
    if race.lastLapNum and completed >= race.lastLapNum and not race.finalLap then
      race.finalLap     = true
      race.finalLapLeft = CFG.finalLapGrace
      MP.SendChatMessage(-1, '[RaceManager] CHECKERED FLAG: '
        .. displayName(rec) .. ' wins. Everyone still out is classified as they cross.')
    end
    -- Endurance reaching the DISTANCE: the flag falls on the first car home. Not
    -- for a Laps race, where everyone runs the full distance.
    if race.raceMode == 'endurance' and target and completed >= target
        and not race.finalLap then
      race.finalLap     = true
      race.finalLapLeft = CFG.finalLapGrace
      MP.SendChatMessage(-1, '[RaceManager] CHECKERED FLAG: ' .. displayName(rec)
        .. ' completed the distance. Everyone still out is classified as they cross.')
    end
    local why
    if quali and race.finalLap and not (target and completed >= target) then
      why = 'Qualifying over: you took the flag on the final lap'
    elseif quali then
      why = 'Qualifying session complete: spectating until the flag'
    else
      why = 'You finished the race: spectating until the flag'
    end
    -- A finished car leaves the race (ghosted; back at the flag).
    retireDriver(rec, why)
    print(string.format('[RaceManager] %s completed %d lap(s) at %.3fs (led %d)%s',
      rec.name, completed, race.time, rec.lapsLed, race.finalLap and ' [final lap]' or ''))
    if quali and target and completed >= target then
      -- The allowance, not the crossing count it became.
      local used = race.qualiLapLimit
      MP.SendChatMessage(-1, string.format('[RaceManager] %s has used all %d qualifying lap%s.',
        displayName(rec), used, used == 1 and '' or 's'))
    elseif race.finalLap then
      MP.SendChatMessage(-1, string.format('[RaceManager] %s has taken the flag (%d still out).',
        displayName(rec), driversOnTrack()))
    end
    -- Everyone done (finished or dnf)? Close the session.
    if driversOnTrack() > 0 then
      broadcastState()
      return
    end
    -- ARM THE HOLD rather than close at once (idempotent: a bunched finish must
    -- not push it further away). Only the automatic ending is held; the phase
    -- stays 'racing' underneath, so ghosts and the flag stay up.
    local why = race.finalLap and 'every driver took the flag'
      or (quali and 'every driver used their lap allowance' or 'all drivers finished')
    -- Races only: nobody watches a qualifying finish.
    if quali then
      finishSession(why)
      return
    end
    if race.endsAt then
      broadcastState()
      return
    end
    if race.endDelay <= 0 then
      finishSession(why)
      return
    end
    race.endsAt    = race.time + race.endDelay
    race.endReason = why
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] %s: results in %d seconds.', why, race.endDelay))
    print('[RaceManager] Race decided (' .. why .. '), closing in '
      .. race.endDelay .. 's')
    broadcastState()
    return
  end
  rec.currentLap = completed + 1
  broadcastState()
end

-- Clear Results Cache: delete every saved results file. ADMIN ONLY (the
-- league's only record, no undo); a race director's local copies are cleared on
-- the client.
function RM_onClearResults(pid)
  if not auth.requireFull(pid) then return end
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

-- A client asks for state (the app opened, or it just joined).
function RM_onRequestState(pid, rawData)
  broadcastState(pid)
  -- ...and the track, so a late arrival gets the gates. Not to a client that
  -- has one: a UI reload asks again, and the public track would replace its
  -- practice or private editor track.
  local ok, data = pcall(Util.JsonDecode, rawData or '')
  if not (ok and type(data) == 'table' and data.haveTrack == true) then
    race.sendLayoutTo(pid)
  end
  -- ...and the Garage List (not on the state push).
  if race.garagePush then race.garagePush(pid) end
end

-- ---------------------------------------------------------------------------
-- Track layouts: persistent, per-map checkpoint configurations
-- ---------------------------------------------------------------------------
-- Named gate routes, per BeamNG level; the UI only sees this map's. Loading
-- one broadcasts it to every client. Every path hangs off DATA_DIR.
local LAYOUTS_DIR  = DATA_DIR
local LAYOUTS_FILE = LAYOUTS_DIR .. '/layouts.json'
-- ONE FILE PER MAP in a folder ("Race Layout", spaces and all, beside "Derby
-- Arena"; every path is quoted where it reaches a shell). The old flat
-- layouts.json is read ONCE, to migrate, when the folder does not exist; after
-- that it is kept as a backup and never read (merging it would resurrect
-- deleted layouts).
local LAYOUTS_TRACKS = LAYOUTS_DIR .. '/Race Layout'
local MAX_LAYOUT_NAME = 40
local layouts = nil  -- lazy-loaded array of { name, map, width, checkpoints }

-- Self-contained JSON for the files on disk (Util.JsonEncode is for the
-- network), so the headless tests exercise the real file format.
local function jsonStringify(v, indent)
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
  if t ~= 'table' then return 'null' end

  -- LAID OUT FOR SOMEBODY TO OPEN (admins hand-edit these):
  --   * a NESTED object or array of scalars is one line (a checkpoint is a
  --     line, not six); the root never is (config.json is a flat object),
  --   * keys are SORTED, so a save does not reorder the file and diffs work.
  -- The parser skips whitespace, so hand-reformatted files still read.
  local pad   = indent or ''
  local inner = pad .. '  '
  local parts, leaf = {}, true

  if #v > 0 or next(v) == nil then  -- array (empty tables encode as [])
    for _, item in ipairs(v) do
      if type(item) == 'table' then leaf = false end
      parts[#parts + 1] = jsonStringify(item, inner)
    end
    if #parts == 0 then return '[]' end
    if leaf and pad ~= '' then return '[' .. table.concat(parts, ', ') .. ']' end
    return '[\n' .. inner .. table.concat(parts, ',\n' .. inner) .. '\n' .. pad .. ']'
  end

  local keys = {}
  for k in pairs(v) do
    if type(k) == 'string' then keys[#keys + 1] = k end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if type(v[k]) == 'table' then leaf = false end
    parts[#parts + 1] = jsonStringify(k) .. ': ' .. jsonStringify(v[k], inner)
  end
  if #parts == 0 then return '{}' end
  if leaf and pad ~= '' then return '{' .. table.concat(parts, ', ') .. '}' end
  return '{\n' .. inner .. table.concat(parts, ',\n' .. inner) .. '\n' .. pad .. '}'
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

-- The hosted level, normalised from "/levels/<name>/info.json" to "<name>".
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
  makeDirectory(LAYOUTS_DIR)
end

-- Copy one small file whole (the migration only).
local function copyFile(from, to)
  local src = io.open(from, 'rb')
  if not src then return false end
  local body = src:read('*a')
  src:close()
  local dst = io.open(to, 'wb')
  if not dst then return false end
  dst:write(body)
  dst:close()
  return true
end

-- MOVE THE SERVER'S OWN DATA UNDER Data/, once, before anything is read
-- (onInit). COPIES and leaves the originals as a backup (never read again).
-- Keyed on Data/ being ABSENT, so a deliberately emptied Data/ stays empty.
local function migrateToDataFolder()
  local probe = io.open(DATA_DIR .. '/.rm', 'a')
  if probe then
    probe:close()
    removeFile(DATA_DIR .. '/.rm')
    return                      -- already migrated
  end
  makeDirectory(DATA_DIR)
  local moved = 0
  for _, name in ipairs({ 'config.json', 'cup.json', 'roster.json', 'garage.json',
                          'layouts.json', 'derbyArenas.json' }) do
    if copyFile(SERVER_DIR .. '/' .. name, DATA_DIR .. '/' .. name) then
      moved = moved + 1
    end
  end
  -- The flat folders (tracks, arenas, results), file by file.
  for _, sub in ipairs({ 'Race Layout', 'Derby Arena', 'results' }) do
    local from = SERVER_DIR .. '/' .. sub
    local names = listDirectory(from)
    if #names > 0 then
      makeDirectory(DATA_DIR .. '/' .. sub)
      for _, name in ipairs(names) do
        if copyFile(from .. '/' .. name, DATA_DIR .. '/' .. sub .. '/' .. name) then
          moved = moved + 1
        end
      end
    end
  end
  if moved > 0 then
    print(string.format('[RaceManager] Moved %d server file(s) into %s/. The '
      .. 'originals are kept as a backup and are no longer read.', moved, DATA_DIR))
  else
    print('[RaceManager] Created ' .. DATA_DIR .. '/ (nothing to migrate)')
  end
end

-- ---------------------------------------------------------------------------
-- config.json: the settings file, beside layouts.json
-- ---------------------------------------------------------------------------
-- Read once at boot (written with the built-ins on first run). A key the file
-- omits keeps its built-in value and an unknown key is ignored, so a trimmed
-- file and an upgrade are both safe. Every value is validated: one bad line
-- costs that line, not the boot.
local CONFIG_FILE = LAYOUTS_DIR .. '/config.json'

local function applyConfigTable(data)
  if type(data) ~= 'table' then return 0 end
  local applied = 0
  local function num(key, lo, hi)
    local v = tonumber(data[key])
    if v == nil then return end
    if v < lo or v > hi then
      print(string.format('[RaceManager] config.json: %s = %s is outside %s..%s, keeping %s',
        key, tostring(data[key]), tostring(lo), tostring(hi), tostring(CFG[key])))
      return
    end
    CFG[key] = v; applied = applied + 1
  end
  local function bool(key)
    if type(data[key]) ~= 'boolean' then return end
    CFG[key] = data[key]; applied = applied + 1
  end
  local function str(key, allowed)
    local v = data[key]
    if type(v) ~= 'string' or v == '' then return end
    if allowed and not allowed[v] then
      print('[RaceManager] config.json: ' .. key .. ' = "' .. v .. '" is not a valid value, ignored')
      return
    end
    CFG[key] = v; applied = applied + 1
  end

  str('adminPassword')
  -- Not str(): empty is how the moderator tier is turned OFF and must be obeyed.
  if type(data.moderatorPassword) == 'string' then
    CFG.moderatorPassword = data.moderatorPassword; applied = applied + 1
  end
  num('totalLaps', 1, CFG.maxTotalLaps)
  num('maxResets', -1, CFG.maxResetLimit)
  str('resetMode', { inplace = true, checkpoint = true })
  bool('nametags')
  num('countdownFrom', 1, 60)
  num('endDelay', 0, 120)
  bool('paceLap')
  -- paceGreenAt is bounded below paceArmAt (see the ordering checks below).
  num('paceGreenAt', 1, 100)
  num('paceReadyAt', 1, 2000)
  num('paceGreenNear', 0.5, 1000)
  num('paceGreenFar', 0.5, 1000)
  num('paceArmAt', 20, 1000)
  bool('luckyDog')
  -- 0 means a heat runs the race distance.
  num('heatLaps', 0, CFG.maxTotalLaps)
  num('blueFlagWithin', 0.2, 60)
  num('blueFlagClear', 0.2, 120)
  num('qualiLapLimit', 0, CFG.maxQualiLaps)
  num('qualiTimeLimit', 0, CFG.maxQualiTime)
  num('finalLapGrace', 10, 3600)
  bool('ghostOnReset')
  num('ghostMinSeconds', 0, 120)
  num('ghostMaxSeconds', 0, 300)
  num('holdTolerance', 0.1, 10)
  num('holdCorrectEvery', 0.05, 5)
  bool('readyCheck')
  str('mapRestart', { auto = true, watch = true, relaunch = true, exit = true, manual = true })
  num('mapRestartGrace', 10, 3600)
  bool('mapVoting')
  num('mapVotePercent', 1, 100)
  -- min above max would ghost nobody: swapped.
  if CFG.ghostMinSeconds > CFG.ghostMaxSeconds then
    print('[RaceManager] config.json: ghostMinSeconds is above ghostMaxSeconds; swapping them')
    CFG.ghostMinSeconds, CFG.ghostMaxSeconds = CFG.ghostMaxSeconds, CFG.ghostMinSeconds
  end
  -- The green threshold at or above the arming one fires at the release, so
  -- paceArmAt is pushed clear (not swapped: the numbers mean different things).
  if CFG.paceArmAt <= CFG.paceGreenAt then
    CFG.paceArmAt = CFG.paceGreenAt * 2
    print(string.format('[RaceManager] config.json: paceArmAt must be above '
      .. 'paceGreenAt or the green falls at the release; raised it to %.0fm',
      CFG.paceArmAt))
  end
  -- GET READY must come before the green can.
  if CFG.paceGreenFar < CFG.paceGreenNear then
    CFG.paceGreenNear, CFG.paceGreenFar = CFG.paceGreenFar, CFG.paceGreenNear
  end
  if CFG.paceReadyAt < CFG.paceGreenFar then
    CFG.paceReadyAt = CFG.paceGreenFar
    print(string.format('[RaceManager] config.json: paceReadyAt is inside the green '
      .. 'zone, so GET READY could come after the green; raised it to %.0fm', CFG.paceReadyAt))
  end
  -- blueFlagClear at or below blueFlagWithin has no hysteresis and strobes:
  -- pushed clear.
  if CFG.blueFlagClear <= CFG.blueFlagWithin then
    CFG.blueFlagClear = CFG.blueFlagWithin * 2
    print(string.format('[RaceManager] config.json: blueFlagClear must be above '
      .. 'blueFlagWithin or the flag strobes; raised it to %.1fs',
      CFG.blueFlagClear))
  end
  return applied
end

-- What config.json should say, defined once for the writer and the "already
-- this?" test in loadConfigFromDisk (a mismatch would rewrite it every boot).
local function configFileText()
  return jsonStringify({
    adminPassword  = CFG.adminPassword,
    -- Written even when empty, so the tier can be found.
    moderatorPassword = CFG.moderatorPassword,
    totalLaps      = CFG.totalLaps,
    maxResets      = CFG.maxResets,
    resetMode      = CFG.resetMode,
    nametags       = CFG.nametags,
    countdownFrom  = CFG.countdownFrom,
    endDelay       = CFG.endDelay,
    paceLap        = CFG.paceLap,
    paceGreenAt    = CFG.paceGreenAt,
    paceReadyAt    = CFG.paceReadyAt,
    paceGreenNear  = CFG.paceGreenNear,
    paceGreenFar   = CFG.paceGreenFar,
    paceArmAt      = CFG.paceArmAt,
    luckyDog       = CFG.luckyDog,
    heatLaps       = CFG.heatLaps,
    blueFlagWithin = CFG.blueFlagWithin,
    blueFlagClear  = CFG.blueFlagClear,
    qualiLapLimit  = CFG.qualiLapLimit,
    qualiTimeLimit = CFG.qualiTimeLimit,
    finalLapGrace  = CFG.finalLapGrace,
    ghostOnReset   = CFG.ghostOnReset,
    ghostMinSeconds = CFG.ghostMinSeconds,
    ghostMaxSeconds = CFG.ghostMaxSeconds,
    holdTolerance   = CFG.holdTolerance,
    holdCorrectEvery = CFG.holdCorrectEvery,
    readyCheck      = CFG.readyCheck,
    mapRestart      = CFG.mapRestart,
    mapRestartGrace = CFG.mapRestartGrace,
    mapVoting       = CFG.mapVoting,
    mapVotePercent  = CFG.mapVotePercent,
  })
end

saveConfigToDisk = function ()
  ensureLayoutsDir()
  local f = io.open(CONFIG_FILE, 'w')
  if not f then
    print('[RaceManager] Could not write ' .. CONFIG_FILE)
    return false
  end
  f:write(configFileText())
  f:close()
  return true
end

-- Push config.json's values into `race`, which was built before the file was
-- read.
local function applyConfigToRace()
  race.totalLaps      = CFG.totalLaps
  race.maxResets      = CFG.maxResets
  race.resetMode      = CFG.resetMode
  race.nametags       = CFG.nametags
  race.endDelay       = CFG.endDelay
  race.paceLap        = CFG.paceLap
  race.luckyDog       = CFG.luckyDog
  race.heatLaps       = CFG.heatLaps
  race.qualiLapLimit  = CFG.qualiLapLimit
  race.qualiTimeLimit = CFG.qualiTimeLimit
  race.readyCheck     = CFG.readyCheck
  auth.adminPw        = CFG.adminPassword
  auth.modPw          = CFG.moderatorPassword
end

local function loadConfigFromDisk()
  local f = io.open(CONFIG_FILE, 'r')
  if not f then
    -- First run: write the shipped settings as a complete file to edit.
    if saveConfigToDisk() then
      print('[RaceManager] Wrote default settings to ' .. CONFIG_FILE)
    end
    return
  end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' then
    -- A broken file never stops the boot.
    print('[RaceManager] ' .. CONFIG_FILE .. ' could not be read ('
      .. tostring(data) .. '); using built-in defaults')
    return
  end
  local n = applyConfigTable(data)
  -- Rewritten ONCE if not already what we would write: config.json is otherwise
  -- only written on first boot and a password change, so this is how an old file
  -- gains the readable layout and every setting added since. Values are the ones
  -- just loaded. Unknown keys are dropped, and named in the log.
  local unknown = {}
  for k in pairs(data) do
    if CFG[k] == nil then unknown[#unknown + 1] = tostring(k) end
  end
  if #unknown > 0 then
    table.sort(unknown)
    print('[RaceManager] config.json: ' .. table.concat(unknown, ', ')
      .. ' are not settings this plugin has; they do nothing and are not kept')
  end
  print(string.format('[RaceManager] Settings loaded from config.json (%d value%s): '
    .. '%d laps, resets %s, countdown %d, ghost %.0f-%.0fs, pace lap %s',
    n, n == 1 and '' or 's', CFG.totalLaps,
    CFG.maxResets < 0 and 'unlimited' or tostring(CFG.maxResets),
    CFG.countdownFrom, CFG.ghostMinSeconds, CFG.ghostMaxSeconds,
    CFG.paceLap and string.format('on (get ready at %.0fm, green %.0f-%.0fm before the line)',
      CFG.paceReadyAt, CFG.paceGreenNear, CFG.paceGreenFar) or 'off'))
  if text ~= configFileText() then
    if saveConfigToDisk() then
      print('[RaceManager] Rewrote ' .. CONFIG_FILE
        .. ' with every setting, laid out to be edited')
    end
  end
end


-- The file a map's tracks live in, sanitised (a map name comes from a path).
local function layoutFileFor(map)
  local safe = tostring(map or 'unknown'):gsub('[^%w%-_%.]', '_')
  if safe == '' then safe = 'unknown' end
  return LAYOUTS_TRACKS .. '/' .. safe .. '.json'
end

-- Files this process read and PARSED. A save deletes a map file with no layouts
-- in memory, but only one of these: a corrupt file is absent from memory too,
-- and deleting it destroyed a track for good.
local layoutFileParsed = {}

-- Read one map's file. `fallbackMap` (from the filename) only fills an entry
-- with no map of its own.
local function readLayoutFile(path, fallbackMap)
  local f = io.open(path, 'r')
  if not f then return {}, false end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. path
      .. ', skipping it. It is LEFT ALONE, layouts in it are not loaded, and it '
      .. 'will not be deleted or overwritten.')
    return {}, false
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string'
        and type(l.checkpoints) == 'table' and #l.checkpoints > 0 then
      if type(l.map) ~= 'string' or l.map == '' then l.map = fallbackMap end
      if type(l.map) == 'string' and l.map ~= '' then out[#out + 1] = l end
    end
  end
  return out, true
end

-- Every track file in the folder; nil when the folder is MISSING (migrate),
-- {} when empty (the last layout was deleted).
local function readLayoutFolder()
  local names = listDirectory(LAYOUTS_TRACKS)
  if #names == 0 then
    -- Empty or missing? Try to open a file in it.
    local probe = io.open(LAYOUTS_TRACKS .. '/.rm', 'a')
    if not probe then return nil end
    probe:close()
    removeFile(LAYOUTS_TRACKS .. '/.rm')
    return {}
  end
  local out = {}
  for _, name in ipairs(names) do
    local base = name:match('^(.*)%.json$')
    if base then
      local list, parsed = readLayoutFile(LAYOUTS_TRACKS .. '/' .. name, base)
      if parsed then layoutFileParsed[name] = true end
      for _, l in ipairs(list) do
        out[#out + 1] = l
      end
    end
  end
  return out
end

-- The legacy flat file, read only when the folder is not there yet.
local function readLegacyLayouts()
  local f = io.open(LAYOUTS_FILE, 'r')
  if not f then return {} end
  f:close()
  return readLayoutFile(LAYOUTS_FILE, nil)
end

-- Forward declared: a save reads getLayouts, and the first getLayouts saves.
local getLayouts

-- One map's file, written only if it changed, and never in place: to a .tmp,
-- READ BACK (a full disk writes short without raising), then swapped in. A
-- leftover .tmp is a failed write worth keeping. Text mode on both sides: the
-- files keep Windows line endings and the comparison stays exact (mixing 'rb'
-- with 'w' fails it on Windows). Returns 'same', 'wrote', or nil and a message.
local function writeLayoutFile(path, text)
  local cur = io.open(path, 'r')
  if cur then
    local have = cur:read('*a')
    cur:close()
    -- Sorted keys make equal contents equal bytes.
    if have == text then return 'same' end
  end

  local tmp = path .. '.tmp'
  local f, ferr = io.open(tmp, 'w')
  if not f then return nil, tostring(ferr) end
  f:write(text)
  f:close()

  local back = io.open(tmp, 'r')
  local landed = back and back:read('*a') or nil
  if back then back:close() end
  if landed ~= text then
    removeFile(tmp)
    return nil, 'short write to ' .. tmp .. ' (disk full?); ' .. path .. ' left as it was'
  end

  -- os.rename will not replace a file on Windows, so the old one goes first. If
  -- the rename fails the .tmp is KEPT: it is the only good copy.
  removeFile(path)
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    return nil, 'could not put ' .. tmp .. ' in place of ' .. path .. ' ('
      .. tostring(rerr) .. '). The .tmp holds the current layouts; rename it by hand.'
  end
  return 'wrote'
end

local function saveLayoutsToDisk()
  ensureLayoutsDir()
  makeDirectory(LAYOUTS_TRACKS)
  -- Grouped first, so a map with no layouts left shows as an absence.
  local byMap = {}
  for _, l in ipairs(getLayouts()) do
    local m = l.map or 'unknown'
    if not byMap[m] then byMap[m] = {} end
    table.insert(byMap[m], l)
  end
  local failed = nil
  for map, list in pairs(byMap) do
    local path = layoutFileFor(map)
    -- Every map is serialised; only changed ones are written.
    local status, err = writeLayoutFile(path, jsonStringify({
      version = 1, map = map, layouts = list }))
    if not status then
      failed = failed or err
    else
      -- Ours now, so deleting its last layout later removes the file.
      layoutFileParsed[path:match('[^/]+$')] = true
    end
  end
  -- A map whose last layout was deleted loses its file (or the next boot hands
  -- it back), but ONLY files this process parsed or wrote.
  for _, name in ipairs(listDirectory(LAYOUTS_TRACKS)) do
    local base = name:match('^(.*)%.json$')
    if base and layoutFileParsed[name] then
      local live = false
      for map in pairs(byMap) do
        if layoutFileFor(map) == LAYOUTS_TRACKS .. '/' .. name then live = true break end
      end
      if not live then
        removeFile(LAYOUTS_TRACKS .. '/' .. name)
        layoutFileParsed[name] = nil
      end
    end
  end
  if failed then return false, failed end
  return true
end

getLayouts = function ()
  if not layouts then
    local folder = readLayoutFolder()
    if folder then
      layouts = folder
      print(string.format('[RaceManager] Loaded %d saved layout(s) from %s/',
        #layouts, LAYOUTS_TRACKS))
    else
      -- First boot after the upgrade: split the flat file per map, once.
      layouts = readLegacyLayouts()
      print(string.format('[RaceManager] Migrating %d layout(s) from %s into %s/',
        #layouts, LAYOUTS_FILE, LAYOUTS_TRACKS))
      local ok, err = saveLayoutsToDisk()
      if ok then
        print('[RaceManager] Migration done. ' .. LAYOUTS_FILE
          .. ' is kept as a backup and is no longer read.')
      else
        print('[RaceManager] Migration FAILED (' .. tostring(err)
          .. '); still running from ' .. LAYOUTS_FILE)
      end
    end
  end
  return layouts
end

-- Checkpoints as the editor stores them: position, heading, optional size; the
-- same shape serves start positions.
sanitizeCheckpoints = function (raw)
  if type(raw) ~= 'table' then return nil end
  -- Marker symbols, mirroring marker.KINDS on the client. A symbol missing here
  -- is dropped on save and reloads as the default (marker_test compares the
  -- two). Built inside the function for the locals ceiling: save and load only.
  local MARKER_KINDS = {
    right = true, left = true, up = true, down = true,
    uturn = true, splitRight = true, splitLeft = true, pit = true,
  }
  local out = {}
  for i, cp in ipairs(raw) do
    if type(cp) ~= 'table' then return nil end
    local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
    if not (x and y and z) then return nil end
    out[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
    if tonumber(cp.width)  then out[i].width  = tonumber(cp.width)  end
    if tonumber(cp.height) then out[i].height = tonumber(cp.height) end
    -- Depth: how far the gate drops below its placement point (height rises
    -- above). Independent of height.
    if tonumber(cp.depth) then out[i].depth = tonumber(cp.depth) end
    -- A pit stall's length, or the client resets its size on every load.
    if tonumber(cp.length) then out[i].length = tonumber(cp.length) end
    -- oneWay, only when set.
    if cp.oneWay == true then out[i].oneWay = true end
    -- A marker's symbol: stored, never interpreted, but whitelisted because the
    -- client uses it as a lookup key (an unknown one draws nothing).
    if type(cp.kind) == 'string' and MARKER_KINDS[cp.kind] then
      out[i].kind = cp.kind
    end
  end
  if #out == 0 then return nil end
  return out
end

-- Props: static scenery each client spawns from the layout. Mirrors
-- props.CATALOG on the client (prop_test compares the two). An unknown kind is
-- DROPPED, never defaulted: a cone where a wall was saved is another track.
-- Capped and rounded to the centimeter: a whole layout is one BeamMP event.
function race.sanitizeProps(raw)
  if type(raw) ~= 'table' then return nil end
  local KINDS = {
    cone = true, bollard = true, barrel = true, cushion = true,
    jersey = true, jerseyEnd = true, roadBarrier = true, plastic = true,
    plasticRed = true, block = true, crate = true, arrowBoard = true,
    signLeft = true, signRight = true, chevron = true, chevron3 = true,
    cornerLeft = true, cornerRight = true, tape = true,
  }
  local MAX = 200
  local function cm(v) return math.floor(v * 100 + 0.5) / 100 end
  local out = {}
  for _, p in ipairs(raw) do
    if #out >= MAX then
      print('[RaceManager] Props over the cap of ' .. MAX .. ': the rest were dropped')
      break
    end
    if type(p) == 'table' and type(p.kind) == 'string' and KINDS[p.kind] then
      local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
      local hx, hy = tonumber(p.hx) or 0, tonumber(p.hy) or 1
      if x and y and z then
        local len = math.sqrt(hx * hx + hy * hy)
        if len < 1e-6 then hx, hy, len = 0, 1, 1 end
        local e = { kind = p.kind, x = cm(x), y = cm(y), z = cm(z),
                    hx = math.floor(hx / len * 10000 + 0.5) / 10000,
                    hy = math.floor(hy / len * 10000 + 0.5) / 10000 }
        -- Only when switched off: solid is the default.
        if p.solid == false then e.solid = false end
        out[#out + 1] = e
      end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- Branch gates. Rejected, not repaired (a half-loaded layout is not the track
-- that was saved). Every slot is checked against the route length: clamping
-- would arm a gate at another corner. Several may share a slot.
sanitizeBranches = function (raw, slotCount)
  if raw == nil then return nil end
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, g in ipairs(raw) do
    if type(g) ~= 'table' then return nil end
    local slot = tonumber(g.slot)
    if not slot then return nil end
    slot = math.floor(slot)
    if slot < 1 or slot > slotCount then return nil end
    local x, y, z = tonumber(g.x), tonumber(g.y), tonumber(g.z)
    if not (x and y and z) then return nil end
    out[i] = {
      slot = slot, x = x, y = y, z = z,
      hx = tonumber(g.hx) or 0, hy = tonumber(g.hy) or 1,
    }
    if tonumber(g.width)  then out[i].width  = tonumber(g.width)  end
    if tonumber(g.height) then out[i].height = tonumber(g.height) end
    if tonumber(g.depth)  then out[i].depth  = tonumber(g.depth)  end
    if g.oneWay == true   then out[i].oneWay = true end
  end
  if #out == 0 then return nil end
  return out
end

-- Only layouts for the map this server is hosting now.
local function layoutsForCurrentMap()
  local map = getCurrentMap()
  local list = {}
  for _, l in ipairs(getLayouts()) do
    if l.map == map then list[#list + 1] = l end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)
  return list, map
end

-- What this player may see: an admin, every layout; anyone else, only those
-- approved for practice. Authoritative: the others never leave the server.
local function layoutsVisibleTo(pid, list)
  -- isAuthenticated, not requireAuth (which would tell a driver their login
  -- lapsed).
  local admin = pid and isAuthenticated(pid)
  local out = {}
  for _, l in ipairs(list) do
    if admin or l.practice == true then
      -- Props stay out of the list, which carries every layout to every player
      -- in one event; they travel with RM_ApplyLayout. A copy, never the store.
      if type(l.props) == 'table' then
        local v = {}
        for k, val in pairs(l) do v[k] = val end
        v.props, v.propCount = nil, #l.props
        out[#out + 1] = v
      else
        out[#out + 1] = l
      end
    end
  end
  return out
end

local function sendLayoutList(targetPid)
  local all, map = layoutsForCurrentMap()

  -- Broadcast is -1, not nil.
  if targetPid and targetPid ~= -1 then
    local list = layoutsVisibleTo(targetPid, all)
    print(string.format('[RaceManager] Sending layout list to %s: %d of %d layout(s), map %s',
      tostring(targetPid), #list, #all, map))
    MP.TriggerClientEvent(targetPid, 'RM_Layouts',
      Util.JsonEncode({ map = map, layouts = list }))
    return
  end

  -- ONE ADDRESSED LIST PER PLAYER, never a broadcast plus a correction: the two
  -- are not ordered, and an admin was left with the driver-visible (empty) list
  -- two saves in three.
  local sent, withheld = 0, 0
  for pid in pairs(onlinePlayers()) do
    local list = layoutsVisibleTo(pid, all)
    if #list < #all then withheld = withheld + 1 end
    MP.TriggerClientEvent(pid, 'RM_Layouts', Util.JsonEncode({ map = map, layouts = list }))
    sent = sent + 1
  end
  print(string.format('[RaceManager] Sent the layout list to %d player(s): %d layout(s), '
    .. '%d given the practice-only view, map %s', sent, #all, withheld, map))

  -- KEPT, GUARDED: the old broadcast, for a build where MP.GetPlayers() is empty
  -- with players connected.
  if sent == 0 then
    local safe = layoutsVisibleTo(nil, all)
    print('[RaceManager] No players enumerated; falling back to a broadcast of '
      .. #safe .. ' layout(s)')
    MP.TriggerClientEvent(-1, 'RM_Layouts', Util.JsonEncode({ map = map, layouts = safe }))
  end
end

function RM_onRequestLayouts(pid)
  sendLayoutList(pid)
end

-- Approve or withdraw a layout for practice. Allowed mid-session: it changes
-- nothing about the running race.
function RM_onSetLayoutPractice(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data or type(data.name) ~= 'string' then return end

  local list = layoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      l.practice = data.practice == true
      local wrote, werr = saveLayoutsToDisk()
      if not wrote then
        print('[RaceManager] Failed to write ' .. LAYOUTS_FILE .. ': ' .. tostring(werr))
        return
      end
      sendLayoutList(-1)
      MP.SendChatMessage(pid, string.format('[RaceManager] "%s" is %s for practice.',
        l.name, l.practice and 'OPEN' or 'closed'))
      print(string.format('[RaceManager] Layout "%s" practice %s by %s',
        l.name, l.practice and 'ENABLED' or 'disabled', MP.GetPlayerName(pid) or pid))
      return
    end
  end
end

-- A driver stopped practising (End Practice, their lap target, a session).
function RM_onPracticeEnd(pid)
  local rec = players[pidKey(pid)]
  if not rec or not rec.practicing then return end
  local wasGhost = rec.practiceGhost
  rec.practicing, rec.practiceGhost = nil, nil
  print(string.format('[RaceManager] %s stopped practising', rec.name or pid))
  if wasGhost then broadcastState() end
end

-- Ghosted or solid, changed mid-practice.
function RM_onPracticeGhost(pid, rawData)
  local rec = players[pidKey(pid)]
  if not rec or not rec.practicing then return end
  local ok, data = pcall(Util.JsonDecode, rawData or '')
  if not ok or type(data) ~= 'table' then return end
  local on = data.on == true
  if (rec.practiceGhost == true) == on then return end
  rec.practiceGhost = on
  print(string.format('[RaceManager] %s is practising %s', rec.name or pid,
    on and 'ghosted' or 'solid'))
  broadcastState()
end

-- Send the loaded track to one client, or everyone (-1): on join, on a state
-- request and when a grid forms. Idempotent.
function race.sendLayoutTo(target)
  if type(race.layout) ~= 'table' then return false end
  MP.TriggerClientEvent(target or -1, 'RM_ApplyLayout', Util.JsonEncode(race.layout))
  return true
end

-- Track purge: drop the layout cache and order every client to clear its gates,
-- on boot and before a new layout is applied.
local function clearTrackState(reason)
  layouts = nil
  race.layout = nil
  -- The track's rules go with it, or the old out lap rides onto the next track.
  race.gridOffLine = false
  race.slotCount   = 0
  race.branches    = {}
  race.jokerGates  = 0
  MP.TriggerClientEvent(-1, 'RM_ClearTrack', Util.JsonEncode({ reason = reason or 'clear' }))
  -- And the panel: RM_ClearTrack only carries the gates.
  broadcastState()
  print('[RaceManager] Track state cleared: ' .. (reason or 'clear'))
end

-- An explicit full clear (also refreshes everyone's layout list).
function RM_onClearTrackState(pid)
  if not requireAuth(pid) then return end
  clearTrackState('requested by ' .. (MP.GetPlayerName(pid) or pid))
  sendLayoutList(-1)
end

-- Nothing loaded: no race track and no derby arena, one press. The derby is
-- cleared through its own global RM_* handlers (the `derby` local is declared
-- far below and would be a nil global here). Refused mid-session.
function RM_onClearEverything(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] Not while a session is running: end it first.')
    return
  end
  local who = MP.GetPlayerName(pid) or pid
  clearTrackState('cleared by ' .. who)
  sendLayoutList(-1)
  -- An empty boundary and start grid; the derby's settings are left alone, and
  -- each handler refuses on its own during a running derby.
  RM_onDerbyClearBoundary(pid)
  RM_onDerbyClearStarts(pid)
  local msg = '[RaceManager] Everything cleared by ' .. who
    .. ': no race track and no derby arena are loaded.'
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Save the client's bundle as a named layout for this map; the same name
-- overwrites. Every rejection is logged.
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
  -- What is stored under this name already, for the silent-drop guard below.
  local existing = nil
  for _, l in ipairs(getLayouts()) do
    if l.map == map and l.name:lower() == name:lower() then existing = l; break end
  end
  local entry = {
    name        = name,
    map         = map,
    width       = tonumber(data.width)  or 20,
    height      = tonumber(data.height) or 8,
    depth       = tonumber(data.depth)  or 2,
    checkpoints = checkpoints,
    -- Optional joker route.
    joker       = sanitizeCheckpoints(data.joker),
    startPositions = starts,
    -- Optional pit stalls: an area, never in lap validation.
    pits         = sanitizeCheckpoints(data.pits),
    -- The pit lane's entry and exit gates (arrays: a lane may have several ways
    -- in). Optional: without an entry gate the client shows every stall.
    pitEntry     = sanitizeCheckpoints(data.pitEntry),
    pitExit      = sanitizeCheckpoints(data.pitExit),
    markers      = sanitizeCheckpoints(data.markers),
    props        = race.sanitizeProps(data.props),
    pointToPoint = data.pointToPoint == true,
    -- Filed under Drag Strip in the Layouts menu. A circuit cannot be one.
    drag         = data.pointToPoint == true and data.drag == true,
    -- Approved for practice? Opt-in, default false (a track mid-build must not go
    -- public), and carried through a re-save so editing never revokes it.
    practice     = (data.practice == true) or (existing ~= nil and existing.practice == true),
    -- Optional branch gates, validated against the route length.
    branches     = sanitizeBranches(data.branches, #checkpoints),
    -- Grid off the S/F line (see outLapOwed).
    gridOffLine  = data.gridOffLine == true,
  }
  -- A branch array sent but invalid rejects the save.
  if data.branches ~= nil and not entry.branches then
    print('[RaceManager] Save rejected: branch gates malformed '
      .. '(bad or out-of-range checkpoint number, or bad coordinates)')
    return
  end
  -- THE SILENT-DROP GUARD: a save writes what the client holds, so a client path
  -- that empties one section turns a same-name save into data loss. Emptying a
  -- WHOLE section the stored layout has is held for the admin to confirm
  -- (RM_SaveHeld, then confirmDrop).
  if existing and data.confirmDrop ~= true then
    local function had(t) return type(t) == 'table' and #t or 0 end
    local lost = {}
    local function checkSection(key, before, after)
      if before > 0 and after == 0 then lost[key] = before end
    end
    checkSection('joker',          had(existing.joker),          entry.joker and #entry.joker or 0)
    checkSection('pits',           had(existing.pits),           entry.pits and #entry.pits or 0)
    checkSection('pitEntry',       had(existing.pitEntry),       entry.pitEntry and #entry.pitEntry or 0)
    checkSection('pitExit',        had(existing.pitExit),        entry.pitExit and #entry.pitExit or 0)
    checkSection('startPositions', had(existing.startPositions), starts and #starts or 0)
    checkSection('branches',       had(existing.branches),       entry.branches and #entry.branches or 0)
    checkSection('markers',        had(existing.markers),        entry.markers and #entry.markers or 0)
    -- A client from before props sends none at all.
    checkSection('props',          had(existing.props),          entry.props and #entry.props or 0)
    if next(lost) then
      local parts = {}
      for k, n in pairs(lost) do parts[#parts + 1] = n .. ' ' .. k end
      table.sort(parts)
      print('[RaceManager] Save held back: overwriting "' .. name .. '" would drop '
        .. table.concat(parts, ', ') .. ' -- waiting for the admin to confirm')
      MP.TriggerClientEvent(pid, 'RM_SaveHeld', Util.JsonEncode({ name = name, lost = lost }))
      return
    end
  end

  -- Saving tells the server this track's grid size.
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
  local msg = string.format('[RaceManager] Layout "%s" (%d gates%s%s%s, %s) %s by %s',
    name, #checkpoints,
    entry.joker and (' + ' .. #entry.joker .. ' joker gates') or '',
    starts and (' + ' .. #starts .. ' start positions') or '',
    entry.props and (' + ' .. #entry.props .. ' props') or '',
    map, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid)
  MP.SendChatMessage(-1, msg)
  print(msg)
  sendLayoutList(-1)
end

-- Show the field a flag, while a session runs; announced in chat too.
function RM_onSetFlag(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local want = tostring(data.flag or '')
  if want ~= 'green' and want ~= 'yellow' and want ~= 'red' then return end
  if not sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] No session is running, so there is nothing to flag.')
    return
  end
  -- LIFTING A RED IS NOT A GREEN: checked first, the field goes back to the pace
  -- lap or caution it was under; the green or restart is called separately.
  -- A manual green otherwise ends a pace lap (no timeout needed: the marshal can
  -- see the track) through dropGreenFlag.
  if want == 'green' and race.flag == 'red' and (race.pacing or race.caution) then
    race.flag = 'yellow'
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] The red is lifted and the clock runs again: %s. By %s.',
      race.pacing and 'the PACE LAP resumes, hold position'
                  or  'the race is STILL UNDER CAUTION, hold your position',
      tostring(MP.GetPlayerName(pid) or pid)))
    print('[RaceManager] Red lifted back to '
      .. (race.pacing and 'the pace lap' or 'the caution') .. ' by '
      .. tostring(MP.GetPlayerName(pid) or pid))
    broadcastState()
    return
  end
  if want == 'green' and race.pacing then
    dropGreenFlag('green called by ' .. tostring(MP.GetPlayerName(pid) or pid))
    return
  end
  -- A green on a neutralised race IS the restart, through restartRace, or the
  -- order would stay frozen. Kept for chat commands and older clients (the
  -- panel offers Restart instead).
  if want == 'green' and race.caution then
    restartRace('green flag called by ' .. tostring(MP.GetPlayerName(pid) or pid))
    return
  end
  if want == race.flag then return end
  local who = MP.GetPlayerName(pid) or pid
  local wasRed = race.flag == 'red'
  race.flag = want
  if want == 'red' then
    MP.SendChatMessage(-1, '[RaceManager] RED FLAG: stop where you are and wait. '
      .. 'The session is still running; the race clock is stopped until the red '
      .. 'is lifted. By ' .. who .. '.')
  elseif want == 'yellow' then
    MP.SendChatMessage(-1, '[RaceManager] YELLOW FLAG: caution called, race back to the line. '
      .. (wasRed and 'The race clock is running again. ' or '') .. 'By ' .. who .. '.')
  else
    MP.SendChatMessage(-1, '[RaceManager] GREEN FLAG: racing. '
      .. (wasRed and 'The race clock is running again. ' or '') .. 'By ' .. who .. '.')
  end
  print('[RaceManager] Flag set to ' .. want .. ' by ' .. tostring(who))
  broadcastState()
end

-- Delete a saved layout (this map only); refused mid-session. A loaded one is
-- forgotten too. ADMIN ONLY: an evening's work with no undo.
function RM_onDeleteLayout(pid, rawData)
  if not auth.requireFull(pid) then return end
  if sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] Cannot delete a layout while a session is under way.')
    return
  end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local map = getCurrentMap()
  local all = getLayouts()
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == data.name:lower() then
      local gone = l.name
      table.remove(all, i)
      local wrote, werr = saveLayoutsToDisk()
      if not wrote then
        print('[RaceManager] Failed to write ' .. LAYOUTS_FILE .. ': ' .. tostring(werr))
        return
      end
      -- By name, not identity: a public load drops the cache (clearTrackState),
      -- so race.layout is never this table and the loaded track stayed loaded.
      if type(race.layout) == 'table' and race.layout.map == map
         and tostring(race.layout.name):lower() == gone:lower() then
        race.layout = nil
        clearTrackState('deleted the loaded layout "' .. gone .. '"')
      end
      local msg = string.format('[RaceManager] Layout "%s" deleted on %s by %s',
        gone, map, MP.GetPlayerName(pid) or pid)
      MP.SendChatMessage(-1, msg)
      print(msg)
      sendLayoutList(-1)
      return
    end
  end
  print(string.format('[RaceManager] Delete failed: no layout "%s" for map %s', data.name, map))
end

-- Load a saved layout, in one of three senses:
--   forPractice   any player, approved layouts, no session: targeted
--   forEditing    PRIVATE to the admin who asked; no server state moves, so two
--                 admins can build on one map at once
--   neither       PUBLIC: the server's raced track, broadcast to everybody
-- Locked during a session (practice has its own, stricter rule).
function RM_onLoadLayout(pid, rawData)
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end
  -- A practice load is the one any player may send: the admin guard runs after
  -- the payload is known.
  if data.forPractice ~= true then
    if not requireAuth(pid) then return end
    if sessionUnderWay() then return end
  end

  local list, map = layoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- PRACTICE: targeted, returns before any race.* field is touched. The
      -- approval is re-checked here; a client can ask for any name.
      if data.forPractice == true then
        if l.practice ~= true then
          MP.SendChatMessage(pid, string.format(
            '[RaceManager] "%s" is not open for practice.', l.name))
          return
        end
        -- WAITING only: the grid phase is not "under way", and reloading a
        -- driver's gates on the grid would take the race from them. A derby or
        -- drag pass counts as a session too.
        if race.phase ~= 'waiting' or race.derbyUnderWay() or race.dragUnderWay() then
          MP.SendChatMessage(pid,
            '[RaceManager] Practice is for between sessions.')
          return
        end
        MP.TriggerClientEvent(pid, 'RM_ClearTrack', Util.JsonEncode({
          reason = 'loading "' .. l.name .. '" to practice on',
        }))
        MP.TriggerClientEvent(pid, 'RM_ApplyLayout', Util.JsonEncode(l))
        MP.TriggerClientEvent(pid, 'RM_Practice', Util.JsonEncode({
          on = true, layout = l.name,
        }))
        -- For race.practiceRoster; ghosted only on an explicit true.
        local rec = ensurePlayer(pid)
        if rec then
          rec.practicing    = l.name
          rec.practiceGhost = data.ghost == true
        end
        MP.SendChatMessage(pid, string.format(
          '[RaceManager] Practising on "%s". Your laps are timed for you only, '
          .. 'and count for nothing.', l.name))
        print(string.format('[RaceManager] Practice layout "%s" loaded by %s (%s)',
          l.name, MP.GetPlayerName(pid) or pid,
          (rec and rec.practiceGhost) and 'ghosted' or 'solid'))
        broadcastState()
        return
      end
      -- PRIVATE LOAD: targeted purge and apply, returning before any race.* field
      -- moves, so another admin's session notices nothing.
      if data.forEditing == true then
        MP.TriggerClientEvent(pid, 'RM_ClearTrack', Util.JsonEncode({
          reason = 'opening "' .. l.name .. '" in the editor',
        }))
        MP.TriggerClientEvent(pid, 'RM_ApplyLayout', Util.JsonEncode(l))
        MP.SendChatMessage(pid, string.format(
          '[RaceManager] "%s" is open in your editor only. Nobody else has it: '
          .. 'press Load Layout when you want the server on it.', l.name))
        print(string.format(
          '[RaceManager] Layout "%s" opened for editing by %s (private, %d gates)',
          l.name, MP.GetPlayerName(pid) or pid, #l.checkpoints))
        return
      end

      -- PUBLIC LOAD. Purge first, so no gate of the previous layout survives.
      clearTrackState('loading layout "' .. l.name .. '"')
      -- The saved grid is the session's grid, and the hold is judged against it.
      race.startSlots = (type(l.startPositions) == 'table') and #l.startPositions or 0
      race.startPositions = (type(l.startPositions) == 'table') and l.startPositions or {}
      race.pointToPoint = l.pointToPoint == true
      race.dragStrip    = race.pointToPoint and l.drag == true
      -- Branch gates and the grid's relation to the line arrive with the track.
      race.branches    = (type(l.branches) == 'table') and l.branches or {}
      race.gridOffLine = l.gridOffLine == true
      race.slotCount   = #l.checkpoints
      -- The joker follows the loaded track (no route would disqualify the field).
      race.jokerGates  = (type(l.joker) == 'table') and #l.joker or 0
      if race.jokerGates == 0 and race.jokerEnabled then
        race.jokerEnabled = false
        MP.SendChatMessage(-1, '[RaceManager] Joker lap switched off: "' .. l.name
          .. '" has no Joker Route.')
        print('[RaceManager] Joker lap auto-disabled: the loaded track has no joker gates')
      end
      -- ...and the pace lap on a sprint stage (as RM_onSetPointToPoint).
      if race.pointToPoint and race.paceLap then
        race.paceLap = false
        MP.SendChatMessage(-1, '[RaceManager] Pace lap switched off: "' .. l.name
          .. '" is a sprint stage, driven once, with no lap to form up on.')
        print('[RaceManager] Pace lap auto-disabled: the loaded track is point-to-point')
      end
      race.layout = l
      print(string.format('[RaceManager] Broadcasting RM_ApplyLayout: "%s", %d checkpoint(s), %d start position(s), width %s',
        l.name, #l.checkpoints, race.startSlots, tostring(l.width)))
      MP.TriggerClientEvent(-1, 'RM_ApplyLayout', Util.JsonEncode(l))
      -- And the panel: all of the above is session state, and RM_Tick does not
      -- push while waiting (the "click Load Layout twice" bug).
      broadcastState()
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
-- Module 4: vehicle & setup locking (the Garage List)
-- ---------------------------------------------------------------------------
-- An admin drives a car and presses Whitelist; the client captures its exact
-- configuration (model, parts, tuning) as a signature. Enforcement, since the
-- server cannot inspect vehicles:
--   1. onVehicleSpawn / onVehicleEdited: a MODEL not on the list ("jbm") is
--      cancelled before it exists for anyone.
--   2. RM_VehicleConfig: a signature not on the list has its car removed.
-- NOBODY IS EXEMPT: lists are built with Enforcing off, and an empty list never
-- enforces.
local GARAGE_FILE        = LAYOUTS_DIR .. '/garage.json'
local MAX_GARAGE_ENTRIES = 60
local MAX_SIG_LENGTH     = 4000
-- The stored car (parts and tuning) so any machine can spawn an entry, capped
-- on its encoded size (about 6 KB is typical) so a client cannot fill the disk.
local MAX_CFG_LENGTH     = 32000

-- A capture's configuration and its encoded length, or nil. Length 0 means
-- "not measured" and passes: a config that will not encode never reaches disk.
local function garageConfigOf(raw)
  if type(raw) ~= 'table' or type(raw.parts) ~= 'table' then return nil, 0 end
  if next(raw.parts) == nil then return nil, 0 end
  local ok, text = pcall(Util.JsonEncode, raw)
  if not ok then return nil, 0 end
  return raw, (type(text) == 'string') and #text or 0
end

local garage = {
  enforce = false,   -- master switch for the whole rule
  -- Which half of the signature is matched:
  --   'parts'  model + parts; tuning and paint free (the default)
  --   'strict' model + parts + tuning
  -- Several allowed builds of one car are several entries, not a third mode.
  mode    = 'parts',
  -- { { model, label, sig, partsSig, game, class, name, pc, cfg } }
  -- `class` lives on the CAR (GT3 is GT3 whoever drives it); none anywhere
  -- keeps every class rule inert. `game` is the BeamNG build captured on, so a
  -- rejection can blame an update that renamed parts.
  list    = {},
}
local garageLoaded = false

-- A display name beside the captured label; matching reads neither.
garage.MAX_NAME = 40
function garage.nameOf(e)
  return e.name or e.label
end

-- Control characters out, spaces collapsed, capped; nil for nothing left.
-- VALID UTF-8 ONLY: Util.JsonEncode throws on a broken byte.
function garage.cleanName(raw)
  if type(raw) ~= 'string' then return nil end
  local s = raw:gsub('%c', ' ')
  if not utf8.len(s) then s = s:gsub('[\128-\255]', '') end
  s = s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if s == '' then return nil end
  if utf8.len(s) > garage.MAX_NAME then
    s = s:sub(1, utf8.offset(s, garage.MAX_NAME + 1) - 1):gsub(' $', '')
  end
  return s
end

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
  -- Anything but 'strict' is 'parts' (the looser default for an old file).
  garage.mode = (data.mode == 'strict') and 'strict' or 'parts'
  garage.list = {}
  local derived = 0
  for _, e in ipairs(type(data.list) == 'table' and data.list or {}) do
    if type(e) == 'table' and type(e.sig) == 'string' and e.sig ~= '' then
      -- An entry from before the split has only the full signature; its parts
      -- half is the PREFIX before the LAST '|vars=' (greedy).
      local partsSig = e.partsSig
      if type(partsSig) ~= 'string' or partsSig == '' then
        partsSig = e.sig:match('^(.*)|vars=')
        if partsSig then derived = derived + 1 end
      end
      garage.list[#garage.list + 1] = {
        model    = tostring(e.model or '?'),
        label    = tostring(e.label or e.model or 'Vehicle'),
        name     = garage.cleanName(e.name),
        -- nil, not '', for unclassified.
        class    = (type(e.class) == 'string' and e.class ~= '') and e.class or nil,
        sig      = e.sig,
        -- nil only for a signature with no vars marker (none written by any
        -- release): it matches in strict mode only.
        partsSig = partsSig,
        game     = (type(e.game) == 'string' and e.game ~= '') and e.game or nil,
        pc       = (type(e.pc) == 'string' and e.pc ~= '') and e.pc or nil,
        -- The car itself; absent on old entries (the `pc` fallback).
        cfg      = (garageConfigOf(e.cfg)),
      }
    end
  end
  if derived > 0 then
    print('[RaceManager] Garage list: derived the parts signature for '
      .. derived .. ' entr' .. (derived == 1 and 'y' or 'ies') .. ' captured before '
      .. 'parts/tuning were split (no re-capture needed)')
  end
end

local function getGarage()
  if not garageLoaded then
    garageLoaded = true
    loadGarageFromDisk()
    print('[RaceManager] Garage list: ' .. #garage.list .. ' approved vehicle(s), enforcement '
      .. (garage.enforce and ('ON (' .. garage.mode .. ')') or 'off'))
  end
  return garage
end

-- The compact view, cached until the garage changes (nil rebuilds).
local garageView = nil

-- The list goes out on its own event (RM_Garage), on a change and on request:
-- on every RM_Update it was half of each push at 60 cars. `seq` orders pushes
-- (a client drops an older one); `boot` tells a restarted server's seq apart.
garage.seq, garage.boot = 0, os.time()

function race.garagePush(target)
  local v = garageSnapshot()
  MP.TriggerClientEvent(target or -1, 'RM_Garage', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL, boot = garage.boot, seq = garage.seq,
    garage = v.list, garageEnforce = v.enforce, garageMode = v.mode, garageSets = v.sets,
  }))
end

-- The list, the switch, the mode or the set names changed: rebuild, tell everyone.
function garage.changed()
  garageView = nil
  garage.seq = garage.seq + 1
  race.garagePush(-1)
end

local function saveGarageToDisk()
  -- Persisting and announcing are one event.
  garage.changed()
  -- And the drivers are re-judged against the new list at once (clients only
  -- re-declare on their own change).
  if garageRejudge then garageRejudge() end
  ensureLayoutsDir()
  local f, ferr = io.open(GARAGE_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({
    -- v2 mode and partsSig, v3 class, v4 cfg, v5 name. Every older file loads.
    version = 5, enforce = getGarage().enforce, mode = getGarage().mode,
    list = getGarage().list,
  }))
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- NAMED GARAGE SETS: a series in a file
-- ---------------------------------------------------------------------------
-- The approved list saved under a name ("GT3", "Trucks") and loaded back. One
-- file per set, hand-editable and copyable. NOT keyed by map: a GT3 field races
-- anywhere. A set carries the lock MODE, never the enforcement switch (a load
-- must not start or stop policing). One table for the locals ceiling.
local gset = {
  DIR = LAYOUTS_DIR .. '/Garage',
  MAX = 30,
  MAX_NAME = 40,
}

-- Sanitised like layoutFileFor: this reaches a filesystem and a shell.
function gset.fileFor(name)
  local safe = tostring(name or ''):gsub('[^%w%-_%. ]', '_')
  if safe == '' then safe = 'unnamed' end
  return gset.DIR .. '/' .. safe .. '.json'
end

-- Trimmed, capped, filename-safe; '' means nothing usable.
function gset.cleanName(raw)
  local s = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
  s = s:gsub('[^%w%-_%. ]', ''):sub(1, gset.MAX_NAME)
  return (s:gsub('%s+$', ''))
end

-- Set names on disk, read from the folder so a hand-dropped set appears.
function gset.names()
  local out = {}
  for _, file in ipairs(listDirectory(gset.DIR)) do
    local base = file:match('^(.*)%.json$')
    if base then out[#out + 1] = base end
  end
  table.sort(out)
  return out
end

function gset.save(name)
  ensureLayoutsDir()
  makeDirectory(gset.DIR)
  local g = getGarage()
  local f, ferr = io.open(gset.fileFor(name), 'w')
  if not f then return false, tostring(ferr) end
  -- No `enforce` key (see above).
  f:write(jsonStringify({ version = 1, name = name, mode = g.mode, list = g.list }))
  f:close()
  return true
end

-- The stored set, or nil and a reason. Does not install it: the caller does,
-- through the one path that persists and re-judges.
function gset.read(name)
  local f = io.open(gset.fileFor(name), 'r')
  if not f then return nil, 'no set called "' .. tostring(name) .. '"' end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.list) ~= 'table' then
    return nil, 'the file for "' .. tostring(name) .. '" could not be read'
  end
  return data
end

-- The cached compact view. SHARED between broadcasts: nothing may write to it.
garageSnapshot = function ()
  if garageView then return garageView end
  -- getGarage() first, so the lazy load has happened.
  local g = getGarage()
  local list = {}
  for i, e in ipairs(g.list) do
    -- Neither the signature nor the stored car rides along (the car is kilobytes,
    -- fetched one entry at a time by RM_onTakeGarageCar): a `spawn` flag instead.
    -- `label` is what to show; `default` the captured label of a renamed entry.
    list[i] = { model = e.model, label = garage.nameOf(e), class = e.class,
                default = e.name and e.label or nil,
                spawn = (e.cfg ~= nil or e.pc ~= nil) or nil }
  end
  -- The saved set names, cached here; writing a set drops the cache.
  garageView = { list = list, enforce = g.enforce, mode = g.mode, sets = gset.names() }
  return garageView
end

-- Enforcement only bites when it is switched on AND at least one car has been
-- captured - an empty whitelist would otherwise lock every player out.
local function garageEnforcing()
  local g = getGarage()
  return g.enforce and #g.list > 0
end

-- WHICH ENTRY THIS CAR IS under the mode in force, or nil: the ONE place the
-- mode is interpreted, and where the class lives. An entry with no partsSig is
-- skipped in parts mode.
local function garageMatch(partsSig, fullSig)
  local strict = getGarage().mode == 'strict'
  for _, e in ipairs(getGarage().list) do
    if strict then
      if fullSig and fullSig ~= '' and e.sig == fullSig then return e end
    else
      if partsSig and partsSig ~= '' and e.partsSig == partsSig then return e end
    end
  end
  return nil
end

-- Re-rule every driver against the list as it stands (from saveGarageToDisk:
-- capture, removal, clear, enforcement and mode). Reads recorded declarations
-- only; no declaration stays nil, "no answer yet", never an offender.
garageRejudge = function ()
  local enforcing = garageEnforcing()
  -- The key is the player id rejectVehicle needs.
  for pid, rec in pairs(players) do
    -- One lookup, two answers: the class is re-derived even when not enforcing,
    -- so a newly tagged entry regroups its drivers at once.
    local entry = rec.carSig and garageMatch(rec.carPartsSig, rec.carSig) or nil
    local was, wasCar = rec.class, rec.carLabel
    rec.class = entry and entry.class or nil
    -- A rename reaches the cars already out, not just the next declaration.
    if entry then rec.carLabel = garage.nameOf(entry) end
    if rec.class ~= was or rec.carLabel ~= wasCar then rememberIdentity(rec) end
    local wasOk = rec.carOk
    if not enforcing or not rec.carSig then
      rec.carOk = nil
    else
      rec.carOk = entry ~= nil
    end
    -- And act on it: a driver sitting still never re-declares, so a list swap
    -- that stops covering them must remove their car here. On the TRANSITION only
    -- (no message storm), and NOT mid-session (garageAudit names offenders at
    -- the countdown).
    if rec.carOk == false and wasOk ~= false and not sessionUnderWay() then
      rejectVehicle(pid, nil, 'the Garage List changed and no longer covers this car')
    end
  end
end

-- Who is about to start in a car the list does not cover, from recorded
-- verdicts. Admins are listed too (never invisible); carOk nil is "not declared
-- yet", not an offender.
garageAudit = function ()
  local bad = {}
  if not garageEnforcing() then return bad end
  for pid, rec in pairs(players) do
    if rec.carOk == false and isEntrant(rec) then
      bad[#bad + 1] = {
        name  = displayName(rec),
        label = rec.carLabel or '?',
        admin = isAuthenticated(pid) and true or false,
      }
    end
  end
  table.sort(bad, function (a, b) return a.name < b.name end)
  return bad
end

-- The bare jbeam name: case, a leading path and .jbeam may differ between the
-- list (getJBeamFilename) and the spawn packet ("jbm").
local function garageModelKey(model)
  if type(model) ~= 'string' or model == '' then return nil end
  model = model:match('([^/]+)$') or model
  model = model:gsub('%.jbeam$', '')
  model = model:lower()
  if model == '' then return nil end
  return model
end

local function garageHasModel(model)
  local wanted = garageModelKey(model)
  if not wanted then return false end
  for _, e in ipairs(getGarage().list) do
    if garageModelKey(e.model) == wanted then return true end
  end
  return false
end

-- An approved MODEL with a mismatched signature, captured on a different game
-- build: a game update renamed parts and the admin must re-capture. nil keeps an
-- ordinary rejection's wording.
local function garageVersionSkew(model, clientGame)
  if type(clientGame) ~= 'string' or clientGame == '' then return nil end
  local wanted = garageModelKey(model)
  if not wanted then return nil end
  for _, e in ipairs(getGarage().list) do
    if garageModelKey(e.model) == wanted and type(e.game) == 'string'
        and e.game ~= '' and e.game ~= clientGame then
      return e
    end
  end
  return nil
end

-- Tell a driver their car is not allowed and have it deleted. THE DELETION IS
-- THE CLIENT'S: MP.RemoveVehicle wants BeamMP's own vehicle id, and the config
-- report carries veh:getID(), so it matched nothing. The MP.RemoveVehicle call
-- is kept for the spawn hook, which has the right id. `advisory` (tell, do not
-- remove) is passed by nobody now that admins are not exempt; KEPT so the rule
-- can be flipped back from the two call sites.
rejectVehicle = function (pid, vid, why, advisory)
  if MP.RemoveVehicle and vid and not advisory then
    pcall(MP.RemoveVehicle, pid, vid)
  end
  MP.TriggerClientEvent(pid, 'RM_VehicleRejected', Util.JsonEncode({
    message = advisory
      and 'Vehicle/Setup not on the Garage List (admin: not removed).'
      or  'Vehicle/Setup not allowed in this session.',
    detail  = why or '',
    -- The client deletes its own car on this flag alone.
    remove  = not advisory,
  }))
  print(string.format('[RaceManager] %s vehicle from %s (%s)',
    advisory and 'Flagged' or 'Rejected',
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
    -- Answered to the admin, or the car is believed listed when it is not.
    print('[RaceManager] Whitelist rejected: missing or oversized configuration signature ('
      .. #sig .. ' bytes, limit ' .. MAX_SIG_LENGTH .. ')')
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false,
      message = sig == ''
        and 'No configuration to capture: the vehicle is still loading, try again'
        or  ('That configuration is too long to store (' .. #sig .. ' bytes, limit '
             .. MAX_SIG_LENGTH .. ')'),
    }))
    return
  end
  local g = getGarage()
  local dupe = nil
  for _, e in ipairs(g.list) do
    if e.sig == sig then dupe = e; break end
  end
  if dupe then
    -- A re-capture of a listed car backfills what an older entry lacks: the
    -- stored parts first, else the config path. Nothing else moves (the
    -- signature matched).
    local incoming = (type(data.pc) == 'string' and data.pc ~= '') and data.pc:sub(1, 200) or nil
    local incomingCfg, cfgLen = garageConfigOf(data.cfg)
    if incomingCfg and cfgLen > MAX_CFG_LENGTH then incomingCfg = nil end
    if incomingCfg and dupe.cfg == nil then
      dupe.cfg = incomingCfg
      if incoming then dupe.pc = incoming end
      saveGarageToDisk()
      broadcastState()
      MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
        added = true,
        message = 'Added the stored parts for "' .. garage.nameOf(dupe)
          .. '", so every driver can take this car',
      }))
      print('[RaceManager] Garage entry "' .. garage.nameOf(dupe) .. '" gained stored parts ('
        .. cfgLen .. ' bytes, by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
      return
    end
    if incoming and dupe.pc ~= incoming then
      local had = dupe.pc
      dupe.pc = incoming
      saveGarageToDisk()
      broadcastState()
      MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
        added = true,
        -- A path alone only works where the file is: say so.
        message = (had and 'Updated' or 'Added') .. ' the saved config path for "'
          .. garage.nameOf(dupe) .. '". This car still has no stored parts, so only '
          .. 'someone who already has that file can take it.',
      }))
      print('[RaceManager] Garage entry "' .. garage.nameOf(dupe) .. '" '
        .. (had and 'repointed to' or 'gained') .. ' config ' .. incoming
        .. ' (by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
      return
    end
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
  -- An older client sends no partsSig: recovered from the prefix, as on load.
  local partsSig = data.partsSig and tostring(data.partsSig) or ''
  if partsSig == '' or #partsSig > MAX_SIG_LENGTH then
    partsSig = sig:match('^(.*)|vars=')
  end
  local newCfg, newCfgLen = garageConfigOf(data.cfg)
  local entry = {
    model    = tostring(data.model or '?'),
    label    = tostring(data.label or data.model or 'Vehicle'),
    sig      = sig,
    partsSig = partsSig,
    game     = (type(data.game) == 'string' and data.game ~= '') and data.game or nil,
    -- The saved config's path (absent for a car edited in the session).
    pc       = (type(data.pc) == 'string' and data.pc ~= '') and data.pc:sub(1, 200) or nil,
    -- The car: what makes an entry spawnable elsewhere. Over the limit it is
    -- dropped, never truncated.
    cfg      = (newCfgLen <= MAX_CFG_LENGTH) and newCfg or nil,
  }
  if newCfg and newCfgLen > MAX_CFG_LENGTH then
    print('[RaceManager] Garage entry "' .. entry.label .. '" came with a '
      .. newCfgLen .. ' byte configuration, over the ' .. MAX_CFG_LENGTH
      .. ' byte limit; stored without it, so only a client that already has the '
      .. 'saved file can take this car')
  end
  g.list[#g.list + 1] = entry
  local wrote, werr = saveGarageToDisk()
  if not wrote then print('[RaceManager] Failed to write ' .. GARAGE_FILE .. ': ' .. tostring(werr)) end
  MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
    added = true, message = 'Added "' .. entry.label .. '" to the Garage List ('
      .. (g.mode == 'strict' and 'Strict: this exact tune'
          or 'Parts: these parts, any tune') .. ')',
  }))
  local msg = string.format('[RaceManager] "%s" added to the Garage List by %s (%d approved)',
    entry.label, MP.GetPlayerName(pid) or pid, #g.list)
  MP.SendChatMessage(-1, msg)
  print(msg)
  broadcastState()
end

-- A driver pressed Take: NOT admin-gated (the entry is approved, and the new car
-- is ruled on like any other). One entry to one player: the stored car is
-- kilobytes, fetched once on a press.
function RM_onTakeGarageCar(pid, rawData)
  local idx = decodeNumber(rawData, 'index')
  if not idx then return end
  idx = math.floor(idx)
  local g = getGarage()
  local e = g.list[idx]
  if not e then
    -- The list moved under them: answered, never dropped.
    MP.TriggerClientEvent(pid, 'RM_GarageCar', Util.JsonEncode({
      rmProtocol = RM_PROTOCOL,
      message = 'That garage entry is gone: the list changed while you were looking at it',
    }))
    return
  end
  if not e.cfg and not e.pc then
    MP.TriggerClientEvent(pid, 'RM_GarageCar', Util.JsonEncode({
      rmProtocol = RM_PROTOCOL,
      message = 'There is no saved car behind "' .. tostring(garage.nameOf(e))
        .. '": an admin has to re-capture it',
    }))
    return
  end
  MP.TriggerClientEvent(pid, 'RM_GarageCar', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    model = e.model, label = garage.nameOf(e),
    -- Both; the client prefers the parts, the path is the fallback.
    cfg = e.cfg, pc = e.pc,
  }))
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
  print('[RaceManager] "' .. garage.nameOf(removed) .. '" removed from the Garage List by '
    .. (MP.GetPlayerName(pid) or pid))
end

-- Tag an entry with a class (empty clears). NOT idle-locked: it regroups the
-- board, it does not change the race.
function RM_onSetGarageClass(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local idx = math.floor(tonumber(data.index) or 0)
  local g = getGarage()
  if idx < 1 or idx > #g.list then return end
  local class = tostring(data.class or '')
  -- Trimmed to the results file's 12-column class field, ASCII only (bytes,
  class = class:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 12)
  -- not characters, are padded).
  class = class:gsub('[^%w%-%. ]', '')
  g.list[idx].class = (class ~= '') and class or nil
  saveGarageToDisk()
  broadcastState()
  print(string.format('[RaceManager] "%s" is now %s (by %s)',
    garage.nameOf(g.list[idx]),
    g.list[idx].class and ('class ' .. g.list[idx].class) or 'unclassified',
    MP.GetPlayerName(pid) or pid))
end

-- Give an entry a display name (empty clears). `was` guards against the list
-- moving: it is addressed by index.
function RM_onSetGarageName(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local idx = math.floor(tonumber(data.index) or 0)
  local g = getGarage()
  local e = g.list[idx]
  if not e then return end
  if type(data.was) == 'string' and data.was ~= garage.nameOf(e) then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'The Garage List changed while you were renaming. Try again.' }))
    return
  end
  local name = garage.cleanName(data.name)
  if name == e.label then name = nil end
  e.name = name
  saveGarageToDisk()
  broadcastState()
  print(string.format('[RaceManager] Garage entry "%s" is now shown as "%s" (by %s)',
    e.label, garage.nameOf(e), MP.GetPlayerName(pid) or pid))
end

-- Save the approved list as a named set.
function RM_onSaveGarageSet(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local name = gset.cleanName(data.name)
  if name == '' then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'That garage set name has nothing usable in it' }))
    return
  end
  local g = getGarage()
  if #g.list == 0 then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'Nothing to save: the Garage List is empty' }))
    return
  end
  -- Overwriting an existing set is allowed at the cap.
  local existing = false
  for _, n in ipairs(gset.names()) do if n == name then existing = true break end end
  if not existing and #gset.names() >= gset.MAX then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'Too many saved garage sets (' .. gset.MAX .. '); delete one first' }))
    return
  end
  local ok, err = gset.save(name)
  if not ok then
    print('[RaceManager] Could not write garage set "' .. name .. '": ' .. tostring(err))
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = 'Could not write that garage set to disk' }))
    return
  end
  garage.changed()       -- the set list changed, and it rides the push
  local msg = string.format('[RaceManager] Garage set "%s" %s by %s (%d car(s), %s)',
    name, existing and 'updated' or 'saved', MP.GetPlayerName(pid) or pid, #g.list, g.mode)
  MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
    added = true, message = 'Saved "' .. name .. '" (' .. #g.list .. ' car(s), '
      .. (g.mode == 'strict' and 'Strict' or 'Parts') .. ')' }))
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Install a saved set, REPLACING the list or ADDING to it (how a multi-class
-- night is built from per-class sets). Idle-locked: a swap mid-race changes who
-- is legal under running cars. One handler: only the last step differs.
function RM_onLoadGarageSet(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local name = gset.cleanName(data.name)
  if name == '' then return end
  local append = data.append == true
  if sessionUnderWay() then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false,
      message = 'Finish the session before ' .. (append and 'adding another'
        or 'loading a different') .. ' garage set' }))
    return
  end
  local stored, why = gset.read(name)
  if not stored then
    MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
      added = false, message = tostring(why) }))
    return
  end
  local g = getGarage()
  -- Adding to an empty list is a load (the mode comes off the set).
  if append and #g.list == 0 then append = false end
  -- Rebuilt as loadGarageFromDisk does, so an old or hand-edited set cannot put
  -- a half-formed entry on the live list.
  local list = {}
  for _, e in ipairs(stored.list) do
    if type(e) == 'table' and type(e.sig) == 'string' and e.sig ~= '' then
      local partsSig = e.partsSig
      if type(partsSig) ~= 'string' or partsSig == '' then
        partsSig = e.sig:match('^(.*)|vars=')
      end
      list[#list + 1] = {
        model    = tostring(e.model or '?'),
        label    = tostring(e.label or e.model or 'Vehicle'),
        name     = garage.cleanName(e.name),
        class    = (type(e.class) == 'string' and e.class ~= '') and e.class or nil,
        sig      = e.sig,
        partsSig = partsSig,
        game     = (type(e.game) == 'string' and e.game ~= '') and e.game or nil,
        pc       = (type(e.pc) == 'string' and e.pc ~= '') and e.pc or nil,
        -- The stored car travels with the set, or it comes back unspawnable.
        cfg      = (garageConfigOf(e.cfg)),
      }
    end
  end
  -- The mode travels with the series; the enforcement switch never does.
  local mode = (stored.mode == 'strict') and 'strict' or 'parts'

  local added, skipped = #list, 0
  if append then
    -- The modes must agree: merging Parts and Strict would silently re-rule one
    -- side's cars.
    if mode ~= g.mode then
      MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
        added = false,
        message = '"' .. name .. '" is a ' .. (mode == 'strict' and 'Strict' or 'Parts')
          .. ' set and the list is ' .. (g.mode == 'strict' and 'Strict' or 'Parts')
          .. '. The two rule cars differently, so they cannot be merged: load it '
          .. 'on its own, or re-save one of them in the other mode.' }))
      return
    end
    -- Deduped on the FULL signature only: two tunes of the same parts are two
    -- entries a driver can spawn.
    local have = {}
    for _, e in ipairs(g.list) do have[e.sig] = true end
    local fresh = {}
    for _, e in ipairs(list) do
      if have[e.sig] then
        skipped = skipped + 1
      else
        have[e.sig] = true
        fresh[#fresh + 1] = e
      end
    end
    -- Refused whole, never part-loaded (the missing cars would be found by a
    -- driver being deleted).
    if #g.list + #fresh > MAX_GARAGE_ENTRIES then
      MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
        added = false,
        message = 'Adding "' .. name .. '" would need ' .. (#g.list + #fresh)
          .. ' entries and the Garage List holds ' .. MAX_GARAGE_ENTRIES
          .. '. Nothing was added.' }))
      return
    end
    for _, e in ipairs(fresh) do g.list[#g.list + 1] = e end
    added = #fresh
  else
    g.list = list
    g.mode = mode
  end
  -- Persists and re-judges every driver.
  saveGarageToDisk()
  broadcastState()
  local dupNote = skipped > 0
    and (', ' .. skipped .. ' already on the list') or ''
  local msg = string.format('[RaceManager] Garage set "%s" %s by %s (%d car(s)%s, %d total, %s%s)',
    name, append and 'added' or 'loaded', MP.GetPlayerName(pid) or pid, added, dupNote,
    #g.list, g.mode == 'strict' and 'Strict' or 'Parts',
    g.enforce and ', enforcing' or ', not enforced')
  MP.TriggerClientEvent(pid, 'RM_GarageResult', Util.JsonEncode({
    added = true,
    message = (append
      and ('Added "' .. name .. '": ' .. added .. ' car(s)' .. dupNote
           .. ', ' .. #g.list .. ' on the list')
      or ('Loaded "' .. name .. '": ' .. added .. ' car(s)'))
      .. ', ' .. (g.mode == 'strict' and 'Strict' or 'Parts')
      .. (g.enforce and '' or ' (enforcement is still off)') }))
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Delete a garage set: ADMIN ONLY (nothing puts it back). Clear Garage is not,
-- because any saved set refills the live list.
function RM_onDeleteGarageSet(pid, rawData)
  if not auth.requireFull(pid) then return end
  local data = adminPayload(pid, rawData)
  if not data then return end
  local name = gset.cleanName(data.name)
  if name == '' then return end
  removeFile(gset.fileFor(name))
  garage.changed()
  print('[RaceManager] Garage set "' .. name .. '" deleted by '
    .. (MP.GetPlayerName(pid) or pid))
end

function RM_onSetGarageEnforce(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getGarage().enforce = data.enabled == true or data.enabled == 1
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] Garage enforcement '
    .. (garage.enforce and ('ENABLED (' .. garage.mode .. ')') or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Parts or Strict; saveGarageToDisk re-judges every driver.
function RM_onSetGarageMode(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local mode = tostring(data.mode or '')
  if mode ~= 'parts' and mode ~= 'strict' then return end
  local g = getGarage()
  if g.mode == mode then return end
  g.mode = mode
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] Garage mode set to ' .. mode .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- A client declared its car's configuration. Recorded whether or not enforcing,
-- so switching it on can audit at once. Admins are refused like everyone (see
-- rejectVehicle to restore the exemption).
function RM_onVehicleConfig(pid, rawData)
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local sig = data.sig and tostring(data.sig) or ''
  if #sig > MAX_SIG_LENGTH then return end
  local partsSig = data.partsSig and tostring(data.partsSig) or ''
  -- An older client sends one signature: its parts half is the prefix.
  if partsSig == '' and sig ~= '' then partsSig = sig:match('^(.*)|vars=') or '' end
  local model = data.model and tostring(data.model) or ''

  -- A signature with no parts ('model=X|parts=', reported a frame too early) is
  -- never ruled on, and the standing verdict is left alone.
  if partsSig == '' or partsSig:match('|parts=$') then return end

  local rec = ensurePlayer(pid)
  local entry = garageMatch(partsSig, sig)
  if rec then
    rec.carSig      = sig
    rec.carPartsSig = partsSig
    -- The list's name for it, so lap records match the Garage tab.
    rec.carLabel    = entry and garage.nameOf(entry)
      or (data.label and tostring(data.label) or model)
    rec.carGame     = data.game and tostring(data.game) or nil
    -- The class does not wait for enforcement: scoring classes without policing
    -- setups is a fair thing to want.
    rec.class = entry and entry.class or nil
    rememberIdentity(rec)
  end

  if not garageEnforcing() then
    -- Not enforcing: clear the verdict rather than leave a stale red mark.
    if rec then rec.carOk = nil end
    return
  end

  local allowed = entry ~= nil
  if rec then rec.carOk = allowed end
  if allowed then return end

  -- Both signatures side by side in the console, for the admin (truncated).
  local shown = (getGarage().mode == 'strict') and sig or partsSig
  print(string.format('[RaceManager] Garage mismatch (%s mode) for %s',
    getGarage().mode, MP.GetPlayerName(pid) or pid))
  print('[RaceManager]   driving: ' .. shown:sub(1, 300))
  for _, e in ipairs(getGarage().list) do
    if garageModelKey(e.model) == garageModelKey(model) then
      local listed = (getGarage().mode == 'strict') and e.sig or e.partsSig
      print('[RaceManager]   listed : ' .. tostring(listed):sub(1, 300))
    end
  end

  local stale = garageVersionSkew(model, data.game and tostring(data.game) or nil)
  if stale then
    rejectVehicle(pid, nil, 'the Garage List entry for "' .. garage.nameOf(stale)
      .. '" was captured on BeamNG ' .. stale.game .. ' and you are on '
      .. tostring(data.game) .. ': a game update can rename vehicle parts, so an '
      .. 'admin needs to re-capture the Garage List')
    return
  end
  -- Naming the mode tells the driver whether to undo a part swap or a tune.
  rejectVehicle(pid, nil, getGarage().mode == 'strict'
    and 'this exact setup is not on the Garage List (Strict: parts AND tuning are locked)'
    or  'these parts are not on the Garage List (Parts: tuning and paint are free, '
        .. 'parts are locked)')
end

-- BeamMP spawn/edit hooks: a model not on the list is cancelled at once
-- (return 1); the setup is ruled on by RM_VehicleConfig.
local function garageModelFromPacket(data)
  if type(data) ~= 'string' then return nil end
  return data:match('"jbm"%s*:%s*"([^"]*)"')
end

function RM_onVehicleSpawn(pid, vid, data)
  if not garageEnforcing() then return end
  local model = garageModelFromPacket(data)
  if model and not garageHasModel(model) then
    rejectVehicle(pid, vid, 'vehicle "' .. model .. '" is not on the Garage List')
    return 1  -- cancel the spawn
  end
end

function RM_onVehicleEdited(pid, vid, data)
  if not garageEnforcing() then return end
  local model = garageModelFromPacket(data)
  if model and not garageHasModel(model) then
    rejectVehicle(pid, vid, 'edited into "' .. model .. '", which is not on the Garage List')
    return 1  -- cancel the edit
  end
end

-- ===========================================================================
-- DEMO DERBY: its own module
-- ===========================================================================
-- Handed stable tables and plain functions once (`players` is cleared in place,
-- never replaced). Its RM_Derby* handlers are globals, reached by name.
local derbyMod = require('derby')

derbyMod.init({
  LAYOUTS_DIR = LAYOUTS_DIR, MAX_LAYOUT_NAME = MAX_LAYOUT_NAME,
  RM_PROTOCOL = RM_PROTOCOL,
  aliasNote = aliasNote, decodeString = decodeString, displayName = displayName,
  ensureLayoutsDir = ensureLayoutsDir, ensureResultsDir = ensureResultsDir,
  -- The filesystem helpers, for the derby's own per-map arena store.
  listDirectory = listDirectory, makeDirectory = makeDirectory,
  removeFile = removeFile,
  forceSpectate = forceSpectate, getCurrentMap = getCurrentMap,
  isEntrant = isEntrant, jsonParse = jsonParse, jsonStringify = jsonStringify,
  onlinePlayers = onlinePlayers, releaseSpectators = releaseSpectators,
  requireAuth = requireAuth, respawnField = respawnField,
  -- Deleting an arena is as irreversible as deleting a layout.
  requireAdmin = auth.requireFull,
  uniqueResultsPath = uniqueResultsPath,
  players = players, race = race, sanitizeCheckpoints = sanitizeCheckpoints,
})

-- Installed by the host; the inert defaults apply if the module fails to load.
race.derbyUnderWay    = derbyMod.underWay
derbyEntryListChanged = derbyMod.entryListChanged



-- ===========================================================================
-- DRAG RACING: its own module, on the derby's pattern
-- ===========================================================================
-- Reads race.startPositions (the lanes) and race.slotCount (a finish to cross)
-- and writes neither: the strip IS the loaded point-to-point layout. In a block,
-- so the handle costs no permanent local.
do
  local mod = require('drag')
  mod.init({
    LAYOUTS_DIR = LAYOUTS_DIR, RM_PROTOCOL = RM_PROTOCOL,
    displayName = displayName, ensureLayoutsDir = ensureLayoutsDir,
    ensureResultsDir = ensureResultsDir, forceSpectate = forceSpectate,
    isEntrant = isEntrant, jsonParse = jsonParse, jsonStringify = jsonStringify,
    onlinePlayers = onlinePlayers, releaseSpectators = releaseSpectators,
    requireAuth = requireAuth, uniqueResultsPath = uniqueResultsPath,
    players = players, race = race,
  })
  race.dragUnderWay     = mod.underWay
  race.dragEntryChanged = mod.entryListChanged
  race.dragWarm         = mod.warm
  race.dragSetCupHooks  = mod.setCupHooks
end


-- ===========================================================================
-- MAP SWITCHING: its own module
-- ===========================================================================
-- A function called in place, not a do-block: its locals come from its own 200
-- (a do-block's count against this chunk while it runs). pcall'd: a failed
-- maps.lua costs the Map row only.
;(function ()
  local ok, mod = pcall(require, 'maps')
  if ok and type(mod) == 'table' then
    mod.paths.data = DATA_DIR
    mod.init({
      CFG = CFG, saveConfig = saveConfigToDisk,
      -- Either tier: a switch is undone by switching back.
      requireAuth = requireAuth, isAdmin = isAuthenticated,
      notifyField = notifyField,
      getCurrentMap = getCurrentMap,
      jsonParse = jsonParse, jsonStringify = jsonStringify,
      listDirectory = listDirectory, makeDirectory = makeDirectory,
      removeFile = removeFile, writeFile = writeLayoutFile,
      -- Why a switch must wait, or nil.
      busy = function ()
        if sessionUnderWay() then return 'a session is running' end
        if race.derbyUnderWay() then return 'a derby is running' end
        if race.dragUnderWay() then return 'a drag pass is running' end
        return nil
      end,
    })
    race.mapsWarm = mod.warm
    race.mapLabel = mod.labelFor
  else
    print('[RaceManager] maps.lua did not load, so map switching is off: ' .. tostring(mod))
  end
end)()

-- ===========================================================================
-- LAP RECORDS: its own module, installed the way maps.lua is and for the
-- same reasons. Scored from finishSession through race.recordsSession.
-- ===========================================================================
;(function ()
  local ok, mod = pcall(require, 'records')
  if not (ok and type(mod) == 'table') then
    print('[RaceManager] records.lua did not load, so lap records are off: ' .. tostring(mod))
    return
  end
  mod.init({
    DATA_DIR = DATA_DIR, race = race, players = players,
    displayName = displayName, fmtLap = fmtLap, getCurrentMap = getCurrentMap,
    mapLabel = function (map) return race.mapLabel and race.mapLabel(map) or map end,
    jsonParse = jsonParse, jsonStringify = jsonStringify, writeFile = writeLayoutFile,
    makeDirectory = makeDirectory, removeFile = removeFile,
    -- Clearing cannot be undone: the admin tier's.
    requireFull = auth.requireFull,
  })
  -- A records fault must never stop a session closing.
  race.recordsSession = function (kind)
    local done, err = pcall(mod.onSession, kind)
    if not done then print('[RaceManager] Lap records failed: ' .. tostring(err)) end
  end
end)()

-- ===========================================================================
-- DRIVER ROSTER (persistent display names)
-- ===========================================================================
-- A cup needs points to follow a driver across races and restarts, but guests
-- have no stable identity. The anchor is an admin's decision written down: a
-- roster entry is a name an admin gave somebody (with the guest name they had).
-- A driver is reattached automatically when the guest name still matches, or
-- by an admin typing the name again (applyAlias lands here). Touches no race
-- state. Roster and cup live in one installer function, called below, so their
-- locals do not count against this chunk; only forward-declared names escape.
local function installRosterAndCup()

-- Assigned by the cup: binding a connection to a real driver hands over the
-- rounds its provisional entry had scored.
local cupAbsorbEntry

local ROSTER_FILE = LAYOUTS_DIR .. '/roster.json'
local MAX_ROSTER_ENTRIES = 200

-- Declared ahead of rosterRemember, which merges through it.
local rosterAbsorb

local roster       = nil   -- lazy-loaded array of { id, name, guest, provisional }
local rosterNextId = 1     -- persisted, so an id is never reused after a restart
-- [pid] = entry id. Runtime only: a binding is about a LIVE connection, and a
-- restored one would hand a name to whoever inherited the id.
local rosterBound  = {}

local function loadRosterFromDisk()
  local f = io.open(ROSTER_FILE, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.entries) ~= 'table' then
    print('[RaceManager] Could not parse ' .. ROSTER_FILE .. ', starting with an empty roster')
    return {}
  end
  local out = {}
  local highest = 0
  for _, e in ipairs(data.entries) do
    local id = tonumber(e and e.id)
    if id and type(e.name) == 'string' and e.name ~= '' then
      out[#out + 1] = {
        id    = math.floor(id),
        name  = e.name,
        guest = (type(e.guest) == 'string' and e.guest ~= '') and e.guest or nil,
        -- Kept: rosterAbsorb only merges a provisional entry.
        provisional = e.provisional == true,
      }
      if id > highest then highest = math.floor(id) end
    end
  end
  rosterNextId = math.max(tonumber(data.nextId) or 0, highest + 1)
  return out
end

local function getRoster()
  if not roster then
    roster = loadRosterFromDisk()
    print('[RaceManager] Driver roster: ' .. #roster .. ' saved display name(s) from ' .. ROSTER_FILE)
  end
  return roster
end

local function saveRosterToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(ROSTER_FILE, 'w')
  if not f then
    print('[RaceManager] Could not write ' .. ROSTER_FILE .. ': ' .. tostring(ferr))
    return false
  end
  f:write(jsonStringify({ version = 1, nextId = rosterNextId, entries = getRoster() }))
  f:close()
  return true
end

local function rosterById(id)
  if not id then return nil end
  for _, e in ipairs(getRoster()) do
    if e.id == id then return e end
  end
  return nil
end

-- Case-insensitive: a retyped name need not match the capitalisation.
local function rosterByName(name)
  if type(name) ~= 'string' then return nil end
  local lower = name:lower()
  for _, e in ipairs(getRoster()) do
    if e.name:lower() == lower then return e end
  end
  return nil
end

-- Is this entry already claimed by somebody else who is connected right now?
local function rosterClaimedBy(entryId, exceptPid)
  for pid, id in pairs(rosterBound) do
    if id == entryId and pid ~= exceptPid then return pid end
  end
  return nil
end

rosterEntryFor = function (rec)
  if not rec then return nil end
  return rosterById(rosterBound[rec.id])
end

rosterUnbind = function (pid)
  if pid == nil then return end
  rosterBound[pid] = nil
end

-- A driver was given a display name:
--   1. the name is in the roster: bind to THAT entry (a reconnect gets its
--      points back);
--   2. this connection is bound under another name: rename it (points stay);
--   3. neither: a new entry.
rosterRemember = function (rec)
  if not rec or not rec.alias then return nil end
  local list  = getRoster()
  local named = rosterByName(rec.alias)
  local bound = rosterById(rosterBound[rec.id])
  local entry
  if named then
    if bound and bound.id ~= named.id then
      print(string.format('[RaceManager] Roster: %s re-bound from "%s" to the existing entry "%s"',
        rec.name, bound.name, named.name))
      -- Their provisional points move with them.
      rosterAbsorb(bound, named)
    end
    -- The spelling just typed is the one kept.
    named.name = rec.alias
    entry = named
  elseif bound then
    print(string.format('[RaceManager] Roster: entry "%s" renamed to "%s"', bound.name, rec.alias))
    bound.name = rec.alias
    entry = bound
  else
    if #list >= MAX_ROSTER_ENTRIES then
      print('[RaceManager] Roster full (' .. MAX_ROSTER_ENTRIES .. ' entries): "'
        .. rec.alias .. '" not saved. Reset the cup or prune the roster.')
      return nil
    end
    entry = { id = rosterNextId, name = rec.alias }
    rosterNextId = rosterNextId + 1
    list[#list + 1] = entry
    print(string.format('[RaceManager] Roster: new entry #%d "%s"', entry.id, entry.name))
  end
  entry.provisional = nil
  -- For the admin's eyes only, never matched on (see rosterEnsure).
  entry.guest = rec.name
  rosterBound[rec.id] = entry.id
  saveRosterToDisk()
  return entry
end

-- Move a PROVISIONAL entry's points onto the entry it turned out to be, then
-- retire it. Never two named entries: they are two drivers.
rosterAbsorb = function (from, into)
  if not from or not into or from.id == into.id then return false end
  if not from.provisional then return false end
  if cupAbsorbEntry then cupAbsorbEntry(from.id, into.id) end
  local list = getRoster()
  for i = #list, 1, -1 do
    if list[i].id == from.id then table.remove(list, i) end
  end
  for pid, id in pairs(rosterBound) do
    if id == from.id then rosterBound[pid] = into.id end
  end
  print(string.format('[RaceManager] Roster: provisional entry "%s" merged into "%s"',
    from.name, into.name))
  return true
end

-- Bind a connected driver to a roster entry: THE "this player is that driver"
-- control. Refuses with a reason rather than guess (a season of points moves).
rosterBindTo = function (rec, entryId)
  if not rec then return false, 'That driver is no longer on the server.' end
  local entry = rosterById(entryId)
  if not entry then return false, 'No such driver in the roster.' end
  local heldBy = rosterClaimedBy(entry.id, rec.id)
  if heldBy then
    local other = players[heldBy]
    return false, '"' .. entry.name .. '" is already assigned to '
      .. (other and other.name or ('player ' .. tostring(heldBy)))
      .. ': unassign them first.'
  end
  if aliasInUse(entry.name, rec.id) then
    return false, 'The name "' .. entry.name .. '" is in use by somebody else on the server.'
  end
  local previous = rosterById(rosterBound[rec.id])
  if previous and previous.id ~= entry.id then
    rosterAbsorb(previous, entry)
  end
  rec.alias = entry.name
  entry.guest = rec.name
  rosterBound[rec.id] = entry.id
  rememberIdentity(rec)
  saveRosterToDisk()
  print(string.format('[RaceManager] Roster: %s bound to "%s"', rec.name, entry.name))
  return true, rec.name .. ' is now racing as "' .. entry.name .. '".'
end

-- Delete an entry (names only; the cup removes its own side).
rosterForget = function (entryId)
  local list = getRoster()
  for i = #list, 1, -1 do
    if list[i].id == entryId then
      local gone = table.remove(list, i)
      for pid, id in pairs(rosterBound) do
        if id == entryId then
          rosterBound[pid] = nil
          local rec = players[pid]
          if rec then rec.alias = nil; rememberIdentity(rec) end
        end
      end
      saveRosterToDisk()
      print('[RaceManager] Roster: entry "' .. gone.name .. '" forgotten')
      return true
    end
  end
  return false
end

-- The roster for the admin panel: entries, who is bound, which are provisional.
rosterList = function ()
  local out = {}
  for i, e in ipairs(getRoster()) do
    out[i] = {
      id = e.id, name = e.name, guest = e.guest,
      provisional = e.provisional == true,
      boundPid = rosterClaimedBy(e.id, nil),
    }
  end
  table.sort(out, function (a, b)
    if a.provisional ~= b.provisional then return b.provisional end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

-- The entry a driver is scored against, created PROVISIONAL if none (dropping an
-- unnamed driver's points would be worse than a "Guest_4471" line to rename).
-- Sets no alias.
local function rosterEnsure(rec)
  if not rec then return nil end
  local entry = rosterEntryFor(rec)
  if entry then return entry end
  local list = getRoster()

  -- Only the DISPLAY NAME may find an existing entry (a disconnected driver is
  -- unbound but still named when scored). The GUEST name is never matched: it is
  -- random per join and would merge strangers' seasons.
  entry = rec.alias and rosterByName(rec.alias) or nil
  if entry and rosterClaimedBy(entry.id, rec.id) then entry = nil end

  if not entry then
    -- A provisional entry of their own: a place to keep points, not a claim.
    if #list >= MAX_ROSTER_ENTRIES then
      print('[RaceManager] Roster full (' .. MAX_ROSTER_ENTRIES
        .. ' entries): ' .. rec.name .. ' could not be entered')
      return nil
    end
    entry = { id = rosterNextId, name = rec.name, provisional = true }
    rosterNextId = rosterNextId + 1
    list[#list + 1] = entry
    print(string.format(
      '[RaceManager] Roster: provisional entry #%d for %s (no display name set): '
        .. 'bind them to a driver to keep their points together',
      entry.id, entry.name))
  end
  entry.guest = rec.name
  rosterBound[rec.id] = entry.id
  saveRosterToDisk()
  return entry
end

-- ===========================================================================
-- CUP / SERIES POINTS (isolated module)
-- ===========================================================================
-- A championship across races; only an admin ending it clears it. A CONSUMER
-- of results only: entered from finishSession (and the derby and drag ends),
-- reading the finished classification, so scoring can never affect who won. It
-- writes only its own tables and the roster, runs nothing per tick, and lives
-- on disk, so sessions, resets and restarts pass through it.

local CUP_FILE = LAYOUTS_DIR .. '/cup.json'
local MAX_CUP_POSITIONS = 60     -- how deep a points table may go
local MAX_CUP_POINTS    = 9999   -- per position, and per bonus
local MAX_CUP_NAME      = 40
local MAX_CUP_ROUNDS    = 200

-- Built-in scoring systems. Selecting one FILLS the table (a starting point). A
-- position past the end scores 0, so no trailing zeroes.
local CUP_PRESETS = {
  { key = '30p-aggressive', label = '30P Aggressive',
    race = { 30, 27, 25, 23, 20, 19, 18, 17, 16, 15, 14, 13,
             12, 11, 10,  9,  8,  7,  6,  5,  4,  3,  2,  1 } },
  { key = '25p-aggressive', label = '25P Aggressive',
    race = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 } },
  { key = '25p-moderate',   label = '25P Moderate',
    race = { 25, 20, 16, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 } },
  { key = '24p-linear',     label = '24P Linear',
    race = { 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13,
             12, 11, 10,  9,  8,  7,  6,  5,  4,  3,  2,  1 } },
  { key = '35p-folk',       label = '35P Folk Race',
    race = { 35, 30, 25, 20, 18, 16, 15, 14, 13, 12, 11,
             10,  9,  8,  7,  6,  5,  4,  3,  2,  1 } },
  -- Podium only: score in the front three or not at all.
  { key = 'collision-course', label = 'Collision Course',
    race = { 3, 2, 1 } },
}

-- Bonuses as DATA: a pot, a discipline (`kind`, so fastest lap is never paid on
-- a derby), and who wins it. A new bonus is one row; the UI builds a control
-- per row.
local CUP_BONUSES = {
  { key = 'fastestLap',  kind = 'race',  label = 'Fastest Lap',
    award = function (ctx) return ctx.awards.fastestLapPid end },
  { key = 'halfwayLed',  kind = 'race',  label = 'Halfway Led',
    award = function (ctx) return ctx.awards.halfWayPid end },
  { key = 'hardCharger', kind = 'race',  label = 'Hard Charger',
    award = function (ctx) return ctx.awards.hardChargerPid end },
  -- Derby: only a real survivor ("last man standing"), not the top of a
  -- classification where everybody was demolished.
  { key = 'derbyWin',    kind = 'derby', label = 'Last Man Standing',
    award = function (ctx) return ctx.winnerPid end },
  -- Drag: the ladder, and the night's quickest single run.
  { key = 'dragWin',     kind = 'drag',  label = 'Event Win',
    award = function (ctx) return ctx.winnerPid end },
  { key = 'dragLowET',   kind = 'drag',  label = 'Low ET',
    award = function (ctx) return ctx.lowETPid end },
}

local function cupBonusesFor(kind)
  local out = {}
  for _, b in ipairs(CUP_BONUSES) do
    if b.kind == kind then out[#out + 1] = b end
  end
  return out
end

local function cupDefaultBonus()
  local t = {}
  for _, b in ipairs(CUP_BONUSES) do t[b.key] = 0 end
  return t
end

-- Built-ins only: this seeds the cup table, so `cup` does not exist yet. Saved
-- systems: cupAnyPresetByKey.
local function cupPresetByKey(key)
  for _, p in ipairs(CUP_PRESETS) do
    if p.key == key then return p end
  end
  return nil
end

local function cupCopyTable(src)
  local out = {}
  for i, v in ipairs(src or {}) do out[i] = v end
  return out
end

local cup = {
  enabled = false,
  name    = '',
  round   = 0,        -- rounds SCORED so far; the next race is round + 1
  scoring = {
    preset = '30p-aggressive',
    race   = cupCopyTable(cupPresetByKey('30p-aggressive').race),
    -- Derbies score on their own table (a derby is not a ten-lap race), with
    -- the same default so an all-derby cup scores at once.
    derbyPreset = '30p-aggressive',
    derby  = cupCopyTable(cupPresetByKey('30p-aggressive').race),
    -- ...and drag a third: a ladder is a meeting. Same default.
    dragPreset = '30p-aggressive',
    drag   = cupCopyTable(cupPresetByKey('30p-aggressive').race),
    -- Empty: qualifying pays nothing unless told to.
    quali  = {},
    bonus  = cupDefaultBonus(),
    -- League rule: the fastest lap pays only with a finish.
    fastestLapRequiresFinish = true,
    -- What a DNF is worth (a league decision):
    --   'none'       nothing (the default)
    --   'classified' its place in the final classification, below every finisher
    --   'held'       the place it was RUNNING in when it stopped, so a retirement
    --                from second and a finish in second both score second
    dnfScoring = 'none',
  },
  -- An ARRAY: the codec emits only string keys, so an integer-keyed map would
  -- save as {} and lose every point.
  entries = {},       -- { { entryId, name, rounds = {}, adjustments = {} } }
  -- Qualifying, held until the race of its round banks it.
  pendingQuali = {},  -- { { entryId, pos, pts } }
  -- Scoring systems an admin saved, shaped like a built-in ({ key, label, race }).
  -- End Cup leaves these alone: a points table outlives the season.
  savedPresets = {},
}
local cupLoaded = false
-- broadcastCupState is forward-declared near the top, for callers above here.

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
-- Beside layouts.json, not under results/, which Clear Results Cache empties.
local function cupSanitizeTable(raw, cap)
  local out = {}
  for i, v in ipairs(type(raw) == 'table' and raw or {}) do
    if i > (cap or MAX_CUP_POSITIONS) then break end
    local n = math.floor(tonumber(v) or 0)
    if n < 0 then n = 0 elseif n > MAX_CUP_POINTS then n = MAX_CUP_POINTS end
    out[i] = n
  end
  -- Trailing zeroes carry nothing (past the end scores 0).
  while #out > 0 and out[#out] == 0 do out[#out] = nil end
  return out
end

local function loadCupFromDisk()
  local f = io.open(CUP_FILE, 'r')
  if not f then return end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Could not parse ' .. CUP_FILE .. ', starting with no cup')
    return
  end
  cup.enabled = data.enabled == true
  cup.name    = type(data.name) == 'string' and data.name:sub(1, MAX_CUP_NAME) or ''
  cup.round   = math.max(math.floor(tonumber(data.round) or 0), 0)

  -- Saved systems, sanitised like a live table; a nameless or empty one is dropped.
  cup.savedPresets = {}
  if type(data.savedPresets) == 'table' then
    for _, p in ipairs(data.savedPresets) do
      local label = type(p.label) == 'string' and p.label or nil
      local tbl   = cupSanitizeTable(p.race)
      if label and label ~= '' and #tbl > 0 then
        cup.savedPresets[#cup.savedPresets + 1] = {
          key   = type(p.key) == 'string' and p.key or ('saved:' .. label:lower()),
          label = label,
          race  = tbl,
        }
      end
    end
  end

  -- Only when the file carries a scoring block: a truncated file must not leave
  -- an empty points table (which reads as "nobody scored").
  if type(data.scoring) == 'table' then
    local s = data.scoring
    cup.scoring.preset = type(s.preset) == 'string' and s.preset or 'custom'
    cup.scoring.race   = cupSanitizeTable(s.race)
    cup.scoring.quali  = cupSanitizeTable(s.quali)
    -- An older cup has no derby table: fall back to the race table, not to zero.
    if s.derby ~= nil then
      cup.scoring.derby = cupSanitizeTable(s.derby)
      cup.scoring.derbyPreset = type(s.derbyPreset) == 'string' and s.derbyPreset or 'custom'
    else
      cup.scoring.derby = cupCopyTable(cup.scoring.race)
      cup.scoring.derbyPreset = cup.scoring.preset
    end
    -- Same for drag.
    if s.drag ~= nil then
      cup.scoring.drag = cupSanitizeTable(s.drag)
      cup.scoring.dragPreset = type(s.dragPreset) == 'string' and s.dragPreset or 'custom'
    else
      cup.scoring.drag = cupCopyTable(cup.scoring.race)
      cup.scoring.dragPreset = cup.scoring.preset
    end
    cup.scoring.bonus  = cupDefaultBonus()
    for _, b in ipairs(CUP_BONUSES) do
      local n = math.floor(tonumber(type(s.bonus) == 'table' and s.bonus[b.key] or 0) or 0)
      if n < 0 then n = 0 elseif n > MAX_CUP_POINTS then n = MAX_CUP_POINTS end
      cup.scoring.bonus[b.key] = n
    end
    cup.scoring.fastestLapRequiresFinish = s.fastestLapRequiresFinish ~= false
    local dnf = tostring(s.dnfScoring or 'none')
    cup.scoring.dnfScoring =
      (dnf == 'classified' or dnf == 'held') and dnf or 'none'
  end

  cup.entries = {}
  for _, e in ipairs(type(data.entries) == 'table' and data.entries or {}) do
    local id = tonumber(e and e.entryId)
    if id and type(e.name) == 'string' then
      local entry = {
        entryId = math.floor(id),
        name    = e.name,
        rounds  = {},
        adjustments = {},
      }
      for _, r in ipairs(type(e.rounds) == 'table' and e.rounds or {}) do
        if type(r) == 'table' then entry.rounds[#entry.rounds + 1] = r end
      end
      for _, a in ipairs(type(e.adjustments) == 'table' and e.adjustments or {}) do
        if type(a) == 'table' and tonumber(a.delta) then
          entry.adjustments[#entry.adjustments + 1] = a
        end
      end
      cup.entries[#cup.entries + 1] = entry
    end
  end

  cup.pendingQuali = {}
  for _, q in ipairs(type(data.pendingQuali) == 'table' and data.pendingQuali or {}) do
    if type(q) == 'table' and tonumber(q.entryId) then
      cup.pendingQuali[#cup.pendingQuali + 1] = {
        entryId = math.floor(tonumber(q.entryId)),
        pos     = math.floor(tonumber(q.pos) or 0),
        pts     = math.floor(tonumber(q.pts) or 0),
      }
    end
  end
end

local function getCup()
  if not cupLoaded then
    cupLoaded = true
    loadCupFromDisk()
    if cup.enabled then
      print(string.format('[RaceManager] Cup "%s" resumed: round %d, %d driver(s)',
        cup.name ~= '' and cup.name or 'unnamed', cup.round, #cup.entries))
    end
  end
  return cup
end

-- Saving IS publishing: every change comes through here, so clients always hear.
local function saveCupToDisk()
  if broadcastCupState then broadcastCupState() end
  ensureLayoutsDir()
  local f, ferr = io.open(CUP_FILE, 'w')
  if not f then
    print('[RaceManager] Could not write ' .. CUP_FILE .. ': ' .. tostring(ferr))
    return false
  end
  f:write(jsonStringify({
    version      = 1,
    enabled      = getCup().enabled,
    name         = cup.name,
    round        = cup.round,
    scoring      = cup.scoring,
    entries      = cup.entries,
    pendingQuali = cup.pendingQuali,
    savedPresets = cup.savedPresets,
  }))
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Standings
-- ---------------------------------------------------------------------------
-- Totals are DERIVED, never stored: a stored total would disagree with the
-- breakdown the first time anything was corrected. Each discipline is totalled
-- on its own and the grand total derived from them.
local function cupEntryTotals(e)
  local t = {
    race  = { rounds = 0, wins = 0, points = 0, quali = 0, bonus = 0, total = 0 },
    derby = { rounds = 0, wins = 0, points = 0, bonus = 0, total = 0 },
    drag  = { rounds = 0, wins = 0, points = 0, bonus = 0, total = 0 },
    adjust = 0, rounds = #e.rounds, total = 0,
  }
  for _, r in ipairs(e.rounds) do
    -- No recognised kind is a race (written before the others existed).
    local kind = (r.kind == 'derby' or r.kind == 'drag') and r.kind or 'race'
    local side = t[kind]
    side.rounds = side.rounds + 1
    side.points = side.points + (tonumber(r.racePts) or 0)
    -- A race is won by finishing first, a derby by being last running and a drag
    -- meeting by taking the ladder. Topping an ended-early classification wins
    -- nothing, or the wins column would disagree with the bonus.
    if kind == 'race' then
      if tonumber(r.racePos) == 1 then side.wins = side.wins + 1 end
    elseif r.status == 'winner' then
      side.wins = side.wins + 1
    end
    for _, b in ipairs(CUP_BONUSES) do
      side.bonus = side.bonus + (tonumber(r.bonus and r.bonus[b.key]) or 0)
    end
    if kind == 'race' then
      t.race.quali = t.race.quali + (tonumber(r.qualiPts) or 0)
    end
  end
  t.race.total  = t.race.points + t.race.quali + t.race.bonus
  t.derby.total = t.derby.points + t.derby.bonus
  t.drag.total  = t.drag.points + t.drag.bonus
  for _, a in ipairs(e.adjustments) do
    t.adjust = t.adjust + (tonumber(a.delta) or 0)
  end
  -- Adjustments correct the CUP standing, outside every discipline.
  t.total = t.race.total + t.derby.total + t.drag.total + t.adjust
  return t
end

-- Cup standings, best first; ties on wins, then the earlier entry. Each row has
-- a combined position and one per discipline.
local function cupStandings()
  local list = {}
  for _, e in ipairs(getCup().entries) do
    local t = cupEntryTotals(e)
    list[#list + 1] = {
      entryId  = e.entryId,
      name     = e.name,
      rounds   = t.rounds,
      -- Race side.
      raceRounds = t.race.rounds, raceWins = t.race.wins,
      racePts  = t.race.points, qualiPts = t.race.quali,
      raceBonusPts = t.race.bonus, raceTotal = t.race.total,
      -- Derby side.
      derbyRounds = t.derby.rounds, derbyWins = t.derby.wins,
      derbyPts = t.derby.points, derbyBonusPts = t.derby.bonus,
      derbyTotal = t.derby.total,
      -- Drag side.
      dragRounds = t.drag.rounds, dragWins = t.drag.wins,
      dragPts = t.drag.points, dragBonusPts = t.drag.bonus,
      dragTotal = t.drag.total,
      -- Combined.
      wins      = t.race.wins + t.derby.wins + t.drag.wins,
      bonusPts  = t.race.bonus + t.derby.bonus + t.drag.bonus,
      adjustPts = t.adjust,
      total     = t.total,
      -- The ledger, so the right adjustment can be removed.
      adjustments = e.adjustments,
    }
  end
  local function rank(field, winField, posField)
    table.sort(list, function (a, b)
      if a[field] ~= b[field] then return a[field] > b[field] end
      if a[winField] ~= b[winField] then return a[winField] > b[winField] end
      return a.entryId < b.entryId
    end)
    for i, row in ipairs(list) do row[posField] = i end
  end
  rank('raceTotal',  'raceWins',  'racePos')
  rank('derbyTotal', 'derbyWins', 'derbyPos')
  rank('dragTotal',  'dragWins',  'dragPos')
  -- Combined last, so the array is left in the order the summary shows.
  rank('total', 'wins', 'pos')
  return list
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------
-- The cup has its own channel (RM_CupUpdate), pushed on change, never folded
-- into the 3 Hz state broadcast. Presets and bonuses ride along so the panel
-- renders what the server supports.

-- Built-ins, then saved systems. Every preset LOAD goes through this.
local function cupAnyPresetByKey(key)
  local builtin = cupPresetByKey(key)
  if builtin then return builtin end
  for _, p in ipairs(cup.savedPresets or {}) do
    if p.key == key then return p end
  end
  return nil
end

-- The picker's list: built-ins, then saved systems (flagged: only those Delete).
local function cupPresetList()
  local out = {}
  for _, p in ipairs(CUP_PRESETS) do
    out[#out + 1] = { key = p.key, label = p.label }
  end
  for _, p in ipairs(cup.savedPresets or {}) do
    out[#out + 1] = { key = p.key, label = p.label, saved = true }
  end
  return out
end

-- The bonus registry for the panel; `kind` groups each under its table.
local function cupBonusList()
  local out = {}
  for i, b in ipairs(CUP_BONUSES) do
    out[i] = {
      key   = b.key,
      kind  = b.kind,
      label = b.label,
      value = cup.scoring.bonus[b.key] or 0,
    }
  end
  return out
end

broadcastCupState = function (targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_CupUpdate', Util.JsonEncode({
    rmProtocol   = RM_PROTOCOL,
    cupEnabled   = getCup().enabled,
    -- Does a cup EXIST, not is it scoring: a paused cup must not read as "No cup
    -- running" beside Start New Cup.
    cupExists    = (cup.name ~= '' or cup.round > 0 or #cup.entries > 0),
    cupName      = cup.name,
    round        = cup.round,
    preset       = cup.scoring.preset,
    racePoints   = cup.scoring.race,
    derbyPreset  = cup.scoring.derbyPreset,
    derbyPoints  = cup.scoring.derby,
    dragPreset   = cup.scoring.dragPreset,
    dragPoints   = cup.scoring.drag,
    qualiPoints  = cup.scoring.quali,
    bonuses      = cupBonusList(),
    presets      = cupPresetList(),
    fastestLapRequiresFinish = cup.scoring.fastestLapRequiresFinish,
    dnfScoring   = cup.scoring.dnfScoring,
    -- Qualifying entries waiting for the next race to bank them.
    pendingQuali = #cup.pendingQuali,
    standings    = cupStandings(),
    -- The roster and who is connected, for the admin to pair up.
    roster       = rosterList and rosterList() or {},
    connected    = (function ()
      local out = {}
      for _, rec in pairs(players) do
        out[#out + 1] = {
          pid = rec.id, guest = rec.name, alias = rec.alias,
          entryId = rosterEntryFor and (rosterEntryFor(rec) or {}).id or nil,
        }
      end
      table.sort(out, function (a, b) return a.pid < b.pid end)
      return out
    end)(),
  }))
end

function RM_onCupRequestState(pid)
  broadcastCupState(pid)
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------
local function cupFindEntry(entryId)
  for _, e in ipairs(getCup().entries) do
    if e.entryId == entryId then return e end
  end
  return nil
end

-- The cup entry for a driver, created on first sight. Keyed by roster entry, so
-- points survive a reconnect.
local function cupEntryFor(rec)
  local rosterEntry = rosterEnsure(rec)
  if not rosterEntry then return nil end
  local e = cupFindEntry(rosterEntry.id)
  if e then
    -- The roster owns the name.
    e.name = rosterEntry.name
    return e
  end
  e = { entryId = rosterEntry.id, name = rosterEntry.name, rounds = {}, adjustments = {} }
  cup.entries[#cup.entries + 1] = e
  return e
end

-- This driver's championship total, or nil with no entry. READ-ONLY: cupEntryFor
-- would enrol everyone a heat draw looks at. nil, not 0: the draw sorts "not
-- raced" apart from "scored nothing".
cupSeasonPoints = function (rec)
  local rosterEntry = rosterEntryFor and rosterEntryFor(rec) or nil
  if not rosterEntry then return nil end
  local e = cupFindEntry(rosterEntry.id)
  if not e then return nil end
  return cupEntryTotals(e).total
end

local function cupPointsFor(tableRef, pos)
  if not pos or pos < 1 then return 0 end
  return tonumber(tableRef[pos]) or 0
end

-- The qualifying ORDER, by best lap. Not qualiClassification(), which sorts by
-- grid slot: when qualifying ends that is where a driver STARTED it. No lap, no
-- position: left out.
local function cupQualiOrder()
  local list = {}
  for _, rec in pairs(players) do
    if rec.qualiBest then list[#list + 1] = rec end
  end
  table.sort(list, function (a, b)
    if a.qualiBest ~= b.qualiBest then return a.qualiBest < b.qualiBest end
    return a.id < b.id
  end)
  return list
end

-- Qualifying ended: work out its points and HOLD them for the race's round.
local function cupScoreQuali()
  if #cup.scoring.quali == 0 then return end   -- qualifying points are off
  cup.pendingQuali = {}
  for i, rec in ipairs(cupQualiOrder()) do
    local entry = cupEntryFor(rec)
    if entry then
      cup.pendingQuali[#cup.pendingQuali + 1] = {
        entryId = entry.entryId,
        pos     = i,
        pts     = cupPointsFor(cup.scoring.quali, i),
      }
    end
  end
  saveCupToDisk()
  print(string.format('[RaceManager] Cup: qualifying scored for %d driver(s), held for round %d',
    #cup.pendingQuali, cup.round + 1))
end

local function cupPendingFor(entryId)
  for _, q in ipairs(cup.pendingQuali) do
    if q.entryId == entryId then return q end
  end
  return nil
end

-- Pay out one discipline's bonuses (only its `kind`, so a derby never gets a
-- fastest lap); a zero bonus pays nothing. `byPid` maps a player id to the row
-- being written; a winner nobody scored is dropped.
local function cupAwardBonuses(kind, ctx, byPid)
  for _, b in ipairs(cupBonusesFor(kind)) do
    local worth = tonumber(cup.scoring.bonus[b.key]) or 0
    if worth > 0 then
      local ok, winner = pcall(b.award, ctx)
      local target = ok and winner and byPid[winner] or nil
      if target then
        if b.key == 'fastestLap' and cup.scoring.fastestLapRequiresFinish
            and not target.classified then
          print('[RaceManager] Cup: fastest lap bonus withheld: ' .. target.entry.name
            .. ' did not finish')
        else
          target.row.bonus[b.key] = worth
          print(string.format('[RaceManager] Cup: %s +%d (%s)',
            target.entry.name, worth, b.label))
        end
      end
    end
  end
end

-- A race ended. This is the only place a race round is banked.
local function cupScoreRace()
  if cup.round >= MAX_CUP_ROUNDS then
    print('[RaceManager] Cup: round limit reached (' .. MAX_CUP_ROUNDS .. '), not scoring')
    return
  end
  local final  = raceClassification()
  local awards = sessionAwards(final)
  local round  = cup.round + 1
  local ctx    = { awards = awards, final = final }

  -- Position points: a finisher scores their place, a DSQ nothing (always), a
  -- DNF by dnfScoring.
  local scored, byPid = 0, {}
  for i, rec in ipairs(final) do
    local classified = rec.finishTime ~= nil and rec.status ~= 'dsq'
    local dnf = rec.status == 'dnf'
    -- The position this driver is credited with, or nil for none at all.
    local scorePos = classified and i or nil
    if dnf then
      if cup.scoring.dnfScoring == 'classified' then
        scorePos = i
      elseif cup.scoring.dnfScoring == 'held' then
        -- The place they were RUNNING in; the classification if they stopped
        -- before a running order existed.
        scorePos = rec.heldPos or rec.dnfPos or i
      end
    end
    local entry = cupEntryFor(rec)
    if entry then
      local pending = cupPendingFor(entry.entryId)
      local row = {
        kind     = 'race',
        round    = round,
        -- Only a real finish is a finishing position (and a win).
        racePos  = classified and i or nil,
        dnfPos   = dnf and scorePos or nil,
        racePts  = scorePos and cupPointsFor(cup.scoring.race, scorePos) or 0,
        qualiPos = pending and pending.pos or nil,
        qualiPts = pending and pending.pts or 0,
        bonus    = {},
        status   = classified and 'classified' or (rec.status == 'dsq' and 'dsq' or 'dnf'),
      }
      entry.rounds[#entry.rounds + 1] = row
      byPid[rec.id] = { entry = entry, row = row, classified = classified }
      scored = scored + 1
    end
  end

  cupAwardBonuses('race', ctx, byPid)

  cup.round = round
  cup.pendingQuali = {}
  saveCupToDisk()

  local standings = cupStandings()
  local leader = standings[1]
  print(string.format('[RaceManager] Cup "%s" round %d scored for %d driver(s)',
    cup.name ~= '' and cup.name or 'unnamed', round, scored))
  if leader then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Cup round %d scored: %s leads on %d point%s.',
      round, leader.name, leader.total, leader.total == 1 and '' or 's'))
  end
  -- The round this race banked, for the results file about to be written.
  return round
end

-- A derby ended: one round on the derby side. `classification` is the winner,
-- anyone still running, then the eliminated, last out first. Unlike a race,
-- EVERYBODY in it scores (elimination is how a derby ends). Only a real
-- survivor is 'winner': a derby can end with nobody alive.
local function cupScoreDerby(classification, info)
  if cup.round >= MAX_CUP_ROUNDS then
    print('[RaceManager] Cup: round limit reached (' .. MAX_CUP_ROUNDS .. '), not scoring')
    return
  end
  local round = cup.round + 1
  local winnerPid = nil
  for _, rec in ipairs(classification) do
    if rec.status == 'winner' then winnerPid = rec.id; break end
  end

  local scored, byPid = 0, {}
  for i, rec in ipairs(classification) do
    local entry = cupEntryFor(rec)
    if entry then
      local row = {
        kind    = 'derby',
        round   = round,
        racePos = i,
        racePts = cupPointsFor(cup.scoring.derby, i),
        bonus   = {},
        status  = rec.status == 'winner' and 'winner'
          or (rec.status == 'alive' and 'survived' or 'eliminated'),
      }
      entry.rounds[#entry.rounds + 1] = row
      -- `classified` is the fastest-lap rule's (a race concept): true here.
      byPid[rec.id] = { entry = entry, row = row, classified = true }
      scored = scored + 1
    end
  end

  cupAwardBonuses('derby', { winnerPid = winnerPid, duration = info and info.duration }, byPid)

  cup.round = round
  -- Held qualifying points belong to a RACE round: a derby leaves them.
  saveCupToDisk()

  local standings = cupStandings()
  local leader = standings[1]
  print(string.format('[RaceManager] Cup "%s" round %d (derby) scored for %d driver(s)',
    cup.name ~= '' and cup.name or 'unnamed', round, scored))
  if leader then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Cup round %d (derby) scored: %s leads on %d point%s.',
      round, leader.name, leader.total, leader.total == 1 and '' or 's'))
  end
  -- The round this derby banked, for the results file about to be written.
  return round
end

-- A drag tournament ended: the only place a drag round is banked. Every entrant
-- scores, as with a derby, from the order the ladder handed over.
local function cupScoreDrag(classification, info)
  if cup.round >= MAX_CUP_ROUNDS then
    print('[RaceManager] Cup: round limit reached (' .. MAX_CUP_ROUNDS .. '), not scoring')
    return
  end
  local round = cup.round + 1
  -- The ladder calls its winner `champion`, a derby `winner`: both accepted.
  local winnerPid = nil
  for _, rec in ipairs(classification) do
    if rec.status == 'champion' or rec.status == 'winner' then
      winnerPid = rec.id
      break
    end
  end

  local scored, byPid = 0, {}
  for i, rec in ipairs(classification) do
    local entry = cupEntryFor(rec)
    if entry then
      local row = {
        kind    = 'drag',
        round   = round,
        racePos = i,
        racePts = cupPointsFor(cup.scoring.drag, i),
        bonus   = {},
        -- 'winner' is the ladder taken, not the top of a half-run order. The ROW
        -- says 'winner' either way: cupEntryTotals counts on that word.
        status  = rec.id == winnerPid and winnerPid ~= nil and 'winner' or 'out',
      }
      entry.rounds[#entry.rounds + 1] = row
      -- `classified` is the fastest-lap rule's (a race concept): true here.
      byPid[rec.id] = { entry = entry, row = row, classified = true }
      scored = scored + 1
    end
  end

  cupAwardBonuses('drag', {
    winnerPid = winnerPid,
    -- The meeting's quickest single pass, often not the winner's.
    lowETPid  = info and info.lowETPid,
  }, byPid)

  cup.round = round
  -- Held qualifying points belong to a RACE round: a ladder leaves them.
  saveCupToDisk()

  local standings = cupStandings()
  local leader = standings[1]
  print(string.format('[RaceManager] Cup "%s" round %d (drag) scored for %d driver(s)',
    cup.name ~= '' and cup.name or 'unnamed', round, scored))
  if leader then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Cup round %d (drag) scored: %s leads on %d point%s.',
      round, leader.name, leader.total, leader.total == 1 and '' or 's'))
  end
  return round
end

-- THE entry points, filling the forward declarations. Returns the round a RACE
-- banked, for the results file; qualifying (held, not banked), a cup that is
-- off and one at its round cap return nil.
cupOnSessionComplete = function (kind)
  if not getCup().enabled then return nil end
  if kind == 'quali' then
    cupScoreQuali()
    return nil
  end
  return cupScoreRace()
end

-- The round just banked, as results-file lines; the one call that READS the
-- cup, after the classification is final. `round` is handed down rather than
-- read from cup.round: at the round cap they differ, and this would print the
-- PREVIOUS event's points. nil when there is nothing to say.
cupResultsLines = function (round)
  if not getCup().enabled or not round then return nil end

  -- What each driver scored THIS round, keyed by entry.
  local roundBy, anyRow = {}, false
  for _, e in ipairs(cup.entries) do
    for _, r in ipairs(e.rounds) do
      if r.round == round then
        roundBy[e.entryId] = r
        anyRow = true
        break
      end
    end
  end
  if not anyRow then return nil end

  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local function bonusOf(r)
    local n = 0
    for _, b in ipairs(CUP_BONUSES) do n = n + (tonumber(r.bonus and r.bonus[b.key]) or 0) end
    return n
  end

  local preset = cupPresetByKey(cup.scoring.preset)
  add('')
  add(string.format('--- CUP: %s (round %d) ---',
    cup.name ~= '' and cup.name or 'unnamed cup', round))
  add(string.format(' Scoring: %s to P%d%s | DNF: %s',
    preset and preset.label or 'custom', #cup.scoring.race,
    #cup.scoring.quali > 0 and (', qualifying to P' .. #cup.scoring.quali) or '',
    cup.scoring.dnfScoring))
  -- One table, in championship order: today's points and where they leave you.
  add(string.format('%-5s %-22s %-6s %-6s %-6s %-7s %s',
    'Pos', 'Driver', 'Race', 'Quali', 'Bonus', 'Round', 'Total'))
  for _, s in ipairs(cupStandings()) do
    local r = roundBy[s.entryId]
    local racePts  = r and (tonumber(r.racePts) or 0) or 0
    local qualiPts = r and (tonumber(r.qualiPts) or 0) or 0
    local bonusPts = r and bonusOf(r) or 0
    local roundPts = racePts + qualiPts + bonusPts
    -- Dashes for a driver not in this round: absent is not zero.
    add(string.format('P%-4d %-22s %-6s %-6s %-6s %-7s %d',
      s.pos, s.name,
      r and tostring(racePts)  or '-',
      r and tostring(qualiPts) or '-',
      r and tostring(bonusPts) or '-',
      r and tostring(roundPts) or '-',
      s.total))
  end
  -- Which bonuses were paid, and to whom (a "+2" does not say what for).
  local paid = {}
  for _, b in ipairs(CUP_BONUSES) do
    for _, e in ipairs(cup.entries) do
      local r = roundBy[e.entryId]
      local worth = r and tonumber(r.bonus and r.bonus[b.key]) or nil
      if worth and worth > 0 then
        paid[#paid + 1] = string.format(' %s: %s (+%d)', b.label, e.name, worth)
      end
    end
  end
  if #paid > 0 then
    add('')
    add(' BONUSES THIS ROUND')
    for _, l in ipairs(paid) do add(l) end
  end
  -- Adjustments are listed, or the totals cannot be checked.
  local adjusted = {}
  for _, s in ipairs(cupStandings()) do
    if (s.adjustPts or 0) ~= 0 then
      adjusted[#adjusted + 1] = string.format(' %s: %+d (manual adjustment%s)',
        s.name, s.adjustPts, #(s.adjustments or {}) == 1 and '' or 's')
    end
  end
  if #adjusted > 0 then
    add('')
    add(' ADJUSTMENTS INCLUDED IN THE TOTALS')
    for _, l in ipairs(adjusted) do add(l) end
  end
  return lines
end

-- The round a derby banked, as cupOnSessionComplete; nil when nothing scored.
cupOnDerbyComplete = function (classification, info)
  if not getCup().enabled then return nil end
  -- An empty derby table means derbies do not count in THIS cup: no round and
  -- no derby bonus either (as qualifying).
  if #cup.scoring.derby == 0 then return nil end
  if type(classification) ~= 'table' or #classification == 0 then return nil end
  return cupScoreDerby(classification, info)
end

-- The same for a drag tournament: an empty drag table pays no round and no
-- drag bonus.
cupOnDragComplete = function (classification, info)
  if not getCup().enabled then return nil end
  if #cup.scoring.drag == 0 then return nil end
  if type(classification) ~= 'table' or #classification == 0 then return nil end
  return cupScoreDrag(classification, info)
end

-- ---------------------------------------------------------------------------
-- Admin events
-- ---------------------------------------------------------------------------
function RM_onCupSetEnabled(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup().enabled = data.enabled == true or data.enabled == 1
  saveCupToDisk()
  print('[RaceManager] Cup points ' .. (cup.enabled and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Start a NEW cup, clearing the old one (hence separate from enabling it).
function RM_onCupStart(pid, rawData)
  if not requireAuth(pid) then return end
  local name = decodeString(rawData, 'name') or ''
  name = name:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', ''):sub(1, MAX_CUP_NAME)
  if name:find('[^%w %-%_%.]') then
    print('[RaceManager] Cup name rejected: letters, digits, spaces and - _ . only')
    return
  end
  getCup()
  cup.name    = name
  cup.round   = 0
  cup.entries = {}
  cup.pendingQuali = {}
  cup.enabled = true
  saveCupToDisk()
  MP.SendChatMessage(-1, '[RaceManager] Cup started: '
    .. (name ~= '' and name or 'unnamed') .. '. Points now count across races.')
  print('[RaceManager] Cup "' .. name .. '" started by ' .. (MP.GetPlayerName(pid) or pid))
end

-- End the cup and clear its points: THE only thing that does. The roster stays
-- (names are not cup property).
function RM_onCupReset(pid)
  if not requireAuth(pid) then return end
  getCup()
  local was, rounds = cup.name, cup.round
  cup.enabled = false
  cup.name    = ''
  cup.round   = 0
  cup.entries = {}
  cup.pendingQuali = {}
  saveCupToDisk()
  MP.SendChatMessage(-1, '[RaceManager] Cup ended and standings cleared.')
  print(string.format('[RaceManager] Cup "%s" (%d round(s)) reset by %s',
    was ~= '' and was or 'unnamed', rounds, MP.GetPlayerName(pid) or pid))
end

-- Load a preset into a points table; `target` defaults to the race table.
function RM_onCupSetPreset(pid, rawData)
  if not requireAuth(pid) then return end
  local key = decodeString(rawData, 'preset')
  local preset = key and cupAnyPresetByKey(key)
  if not preset then
    print('[RaceManager] Unknown cup scoring preset: ' .. tostring(key))
    return
  end
  local sent = decodeString(rawData, 'target')
  local target = (sent == 'derby' or sent == 'drag') and sent or 'race'
  getCup()
  if target == 'drag' then
    cup.scoring.dragPreset = preset.key
    cup.scoring.drag = cupCopyTable(preset.race)
  elseif target == 'derby' then
    cup.scoring.derbyPreset = preset.key
    cup.scoring.derby = cupCopyTable(preset.race)
  else
    cup.scoring.preset = preset.key
    cup.scoring.race = cupCopyTable(preset.race)
  end
  saveCupToDisk()
  print('[RaceManager] Cup ' .. target .. ' scoring preset "' .. preset.label
    .. '" applied by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Save the RACE table as a named system, outliving the cup. One table only: a
-- bundle would need a format and a merge rule.
local MAX_SAVED_PRESETS = 30
local MAX_PRESET_NAME   = 28

function RM_onCupSavePreset(pid, rawData)
  if not requireAuth(pid) then return end
  local name = decodeString(rawData, 'name')
  if type(name) ~= 'string' then return end
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then
    MP.SendChatMessage(pid, '[RaceManager] A saved scoring system needs a name.')
    return
  end
  if #name > MAX_PRESET_NAME then name = name:sub(1, MAX_PRESET_NAME) end
  getCup()
  if #cup.scoring.race == 0 then
    MP.SendChatMessage(pid, '[RaceManager] There is nothing to save: the race points table is empty.')
    return
  end
  -- Namespaced: a saved system cannot shadow a built-in key.
  local key = 'saved:' .. name:lower()
  local entry = { key = key, label = name, race = cupCopyTable(cup.scoring.race) }
  local replaced = false
  for i, existing in ipairs(cup.savedPresets) do
    if existing.key == key then cup.savedPresets[i] = entry; replaced = true; break end
  end
  if not replaced then
    if #cup.savedPresets >= MAX_SAVED_PRESETS then
      MP.SendChatMessage(pid, '[RaceManager] Too many saved scoring systems; delete one first.')
      return
    end
    cup.savedPresets[#cup.savedPresets + 1] = entry
  end
  saveCupToDisk()
  local msg = string.format('[RaceManager] Scoring system "%s" %s by %s (%d position%s deep)',
    name, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid,
    #entry.race, #entry.race == 1 and '' or 's')
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Delete a saved system; a built-in says so rather than doing nothing.
function RM_onCupDeletePreset(pid, rawData)
  if not requireAuth(pid) then return end
  local key = decodeString(rawData, 'preset')
  if type(key) ~= 'string' or key == '' then return end
  getCup()
  for i, p in ipairs(cup.savedPresets) do
    if p.key == key then
      table.remove(cup.savedPresets, i)
      saveCupToDisk()
      print('[RaceManager] Saved scoring system "' .. p.label .. '" deleted by '
        .. (MP.GetPlayerName(pid) or pid))
      return
    end
  end
  MP.SendChatMessage(pid, '[RaceManager] That scoring system is built in and cannot be deleted.')
end

-- Custom scoring: every field optional, a present one replaced outright.
function RM_onCupSetScoring(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup()
  local touched = false
  if type(data.race) == 'table' then
    cup.scoring.race = cupSanitizeTable(data.race)
    -- Hand-edited: no longer a preset, so the UI does not name one over it.
    cup.scoring.preset = 'custom'
    touched = true
  end
  if type(data.derby) == 'table' then
    cup.scoring.derby = cupSanitizeTable(data.derby)
    cup.scoring.derbyPreset = 'custom'
    touched = true
  end
  if type(data.drag) == 'table' then
    cup.scoring.drag = cupSanitizeTable(data.drag)
    cup.scoring.dragPreset = 'custom'
    touched = true
  end
  if type(data.quali) == 'table' then
    cup.scoring.quali = cupSanitizeTable(data.quali)
    touched = true
  end
  if type(data.bonus) == 'table' then
    for _, b in ipairs(CUP_BONUSES) do
      local v = data.bonus[b.key]
      if v ~= nil then
        local n = math.floor(tonumber(v) or 0)
        if n < 0 then n = 0 elseif n > MAX_CUP_POINTS then n = MAX_CUP_POINTS end
        cup.scoring.bonus[b.key] = n
      end
    end
    touched = true
  end
  if data.fastestLapRequiresFinish ~= nil then
    cup.scoring.fastestLapRequiresFinish =
      data.fastestLapRequiresFinish == true or data.fastestLapRequiresFinish == 1
    touched = true
  end
  if data.dnfScoring ~= nil then
    local mode = tostring(data.dnfScoring)
    if mode == 'none' or mode == 'classified' or mode == 'held' then
      cup.scoring.dnfScoring = mode
      touched = true
    end
  end
  if not touched then return end
  saveCupToDisk()
  print('[RaceManager] Cup scoring updated by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (race ' .. #cup.scoring.race .. ' deep, derby '
    .. (#cup.scoring.derby > 0 and (#cup.scoring.derby .. ' deep') or 'off')
    .. ', drag '
    .. (#cup.scoring.drag > 0 and (#cup.scoring.drag .. ' deep') or 'off')
    .. ', quali '
    .. (#cup.scoring.quali > 0 and (#cup.scoring.quali .. ' deep') or 'off') .. ')')
end

-- Fold one cup entry into another (the roster's forward declaration): a
-- provisional entry turned out to be a named driver. Rounds are appended, not
-- merged; an admin can see and drop a duplicate. Held qualifying points are
-- keyed by entry, so they are repointed too, or the driver qualified for nothing.
local function cupRepointPending(fromId, toId)
  for _, q in ipairs(cup.pendingQuali) do
    if q.entryId == fromId then q.entryId = toId end
  end
end

cupAbsorbEntry = function (fromId, toId)
  getCup()
  local from = cupFindEntry(fromId)
  if not from then return false end
  local into = cupFindEntry(toId)
  if not into then
    -- Nothing to merge into: the entry just changes hands.
    from.entryId = toId
    cupRepointPending(fromId, toId)
    saveCupToDisk()
    return true
  end
  for _, r in ipairs(from.rounds) do into.rounds[#into.rounds + 1] = r end
  for _, a in ipairs(from.adjustments) do into.adjustments[#into.adjustments + 1] = a end
  cupRepointPending(fromId, toId)
  for i = #cup.entries, 1, -1 do
    if cup.entries[i].entryId == fromId then table.remove(cup.entries, i) end
  end
  print(string.format('[RaceManager] Cup: %d round(s) and %d adjustment(s) moved to "%s"',
    #from.rounds, #from.adjustments, into.name))
  saveCupToDisk()
  return true
end

-- ---------------------------------------------------------------------------
-- Driver identity (admin-controlled)
-- ---------------------------------------------------------------------------
-- Assign a connected player to a roster entry: how a driver gets their name and
-- points back. An admin action, because BeamMP's guest names are random.
function RM_onCupBindDriver(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local target = tonumber(data.pid)
  local entryId = tonumber(data.entryId)
  if not target then return end
  local rec = players[math.floor(target)]
  if not rec then
    MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
      success = false, message = 'That driver is no longer on the server.' }))
    return
  end

  -- entryId 0 or absent unassigns: the entry and its points stay.
  if not entryId or entryId <= 0 then
    rosterUnbind(rec.id)
    rec.alias = nil
    rememberIdentity(rec)
    broadcastState()
    if broadcastCupState then broadcastCupState() end
    MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
      success = true, message = rec.name .. ' is unassigned.' }))
    print('[RaceManager] Roster: ' .. rec.name .. ' unassigned by '
      .. (MP.GetPlayerName(pid) or pid))
    return
  end

  local bound, msg = rosterBindTo(rec, math.floor(entryId))
  if bound then
    broadcastState()
    if broadcastCupState then broadcastCupState() end
  end
  MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
    success = bound, message = msg }))
end

-- Delete a roster entry and the cup's record of it (stale placeholders).
function RM_onCupForgetDriver(pid, rawData)
  if not requireAuth(pid) then return end
  local entryId = decodeNumber(rawData, 'entryId')
  if not entryId then return end
  entryId = math.floor(entryId)
  if rosterForget(entryId) then
    getCup()
    for i = #cup.entries, 1, -1 do
      if cup.entries[i].entryId == entryId then table.remove(cup.entries, i) end
    end
    saveCupToDisk()
    broadcastState()
    print('[RaceManager] Roster: entry ' .. entryId .. ' forgotten by '
      .. (MP.GetPlayerName(pid) or pid))
  end
end

-- Add a driver who is not here: a league knows its entry list in advance. An
-- UNBOUND entry, offered in the Cup panel and Display Names. Not provisional:
-- an admin typed it.
function RM_onRosterAdd(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local clean, why = sanitizeAlias(tostring(data.name or ''))
  if not clean then
    MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
      success = false, message = 'Name rejected: ' .. tostring(why) .. '.' }))
    return
  end
  local list = getRoster()
  local existing = rosterByName(clean)
  if existing then
    MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
      success = false,
      message = '"' .. existing.name .. '" is already on the roster.' }))
    return
  end
  if #list >= MAX_ROSTER_ENTRIES then
    MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
      success = false,
      message = 'The roster is full (' .. MAX_ROSTER_ENTRIES .. ' drivers).' }))
    return
  end
  local entry = { id = rosterNextId, name = clean }
  rosterNextId = rosterNextId + 1
  list[#list + 1] = entry
  saveRosterToDisk()
  broadcastState()
  if broadcastCupState then broadcastCupState() end
  MP.TriggerClientEvent(pid, 'RM_AliasResult', Util.JsonEncode({
    success = true, message = '"' .. clean .. '" added to the roster.' }))
  print(string.format('[RaceManager] Roster: "%s" added by %s (entry #%d, %d on the roster)',
    clean, MP.GetPlayerName(pid) or pid, entry.id, #list))
end

-- ---------------------------------------------------------------------------
-- Manual adjustments
-- ---------------------------------------------------------------------------
-- Corrections by hand ("minus five, track limits"), kept as a LEDGER beside the
-- earned points, never folded in, each with its reason, author and time.
-- Removing one deletes it: a mistake is not an event.
local MAX_ADJUST      = 9999
local MAX_ADJUST_NOTE = 60

local function cupCleanNote(raw)
  local s = tostring(raw or ''):gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
  -- The display names' character class: this reaches the results export.
  s = s:gsub('[^%w %-%_%.%,%:%(%)/]', '')
  return s:sub(1, MAX_ADJUST_NOTE)
end

-- Adjust one driver's total by cup entry id (the driver, not a session id).
function RM_onCupAdjust(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup()
  if not cup.enabled then
    print('[RaceManager] Cup adjustment ignored: no cup is running')
    return
  end
  local entryId = tonumber(data.entryId)
  local delta   = tonumber(data.delta)
  if not entryId or not delta then return end
  delta = math.floor(delta)
  if delta == 0 then return end
  if delta > MAX_ADJUST then delta = MAX_ADJUST end
  if delta < -MAX_ADJUST then delta = -MAX_ADJUST end
  local entry = cupFindEntry(math.floor(entryId))
  if not entry then
    print('[RaceManager] Cup adjustment ignored: no entry ' .. tostring(entryId))
    return
  end
  entry.adjustments[#entry.adjustments + 1] = {
    delta  = delta,
    reason = cupCleanNote(data.reason),
    by     = MP.GetPlayerName(pid) or ('Player ' .. tostring(pid)),
    at     = os.time(),
  }
  saveCupToDisk()
  local msg = string.format('[RaceManager] Cup: %s %s%d point%s%s',
    entry.name, delta > 0 and '+' or '', delta,
    (delta == 1 or delta == -1) and '' or 's',
    cupCleanNote(data.reason) ~= '' and (': ' .. cupCleanNote(data.reason)) or '')
  MP.SendChatMessage(-1, msg)
  print(msg .. ' (by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
end

-- Remove one adjustment from a driver's ledger, by its index in that ledger.
function RM_onCupRemoveAdjust(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup()
  local entry = cupFindEntry(math.floor(tonumber(data.entryId) or -1))
  local index = math.floor(tonumber(data.index) or 0)
  if not entry or index < 1 or index > #entry.adjustments then return end
  local removed = table.remove(entry.adjustments, index)
  saveCupToDisk()
  print(string.format('[RaceManager] Cup: adjustment of %+d removed from %s by %s',
    removed.delta or 0, entry.name, MP.GetPlayerName(pid) or pid))
end

-- Drop a whole round from a driver's record, to rerun a wrongly scored race.
-- The round COUNT stays: the event took place.
function RM_onCupDropRound(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup()
  local entry = cupFindEntry(math.floor(tonumber(data.entryId) or -1))
  local round = math.floor(tonumber(data.round) or 0)
  if not entry or round < 1 then return end
  local dropped = 0
  for i = #entry.rounds, 1, -1 do
    if tonumber(entry.rounds[i].round) == round then
      table.remove(entry.rounds, i)
      dropped = dropped + 1
    end
  end
  if dropped == 0 then return end
  saveCupToDisk()
  print(string.format('[RaceManager] Cup: round %d dropped from %s by %s',
    round, entry.name, MP.GetPlayerName(pid) or pid))
end

-- Hand the lazy loaders to onInit, which warms them at boot.
rosterWarm, cupWarm = getRoster, getCup

end
installRosterAndCup()

-- Here, after the CALL: these are nil until installRosterAndCup has run, so
-- they cannot go through derbyMod.init (cup_test guards it).
derbyMod.setCupHooks(cupOnDerbyComplete, cupResultsLines)
-- ...and the drag ladder's, through `race` for the same reason.
race.dragSetCupHooks(cupOnDragComplete, cupResultsLines)

-- ===========================================================================
-- End of CUP module
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Clock + lifecycle
-- ---------------------------------------------------------------------------
-- The race clock and the throttled broadcast: the one place the running order
-- is re-sorted, re-numbered and pushed. Clients never trigger it.
function RM_Tick()
  if not sessionRunning() then return end
  -- One clock: race.time stamps every finish; qualifying adds a wall clock.
  local dt = CFG.tickMs / 1000.0
  race.time = race.time + dt
  -- The hold at the flag, first: once it expires there is no session.
  if race.endsAt and race.time >= race.endsAt then
    local reason = race.endReason or 'race over'
    race.endsAt, race.endReason = nil, nil
    finishSession(reason)
    return
  end
  -- A red flag stops the race clocks. race.time cannot stop (ghost end times are
  -- on it), so the anchors move with it instead.
  if race.flag == 'red' then
    race.greenAt = race.greenAt + dt
    if race.raceExpiredAt then race.raceExpiredAt = race.raceExpiredAt + dt end
    tickCounter = tickCounter + 1
    if tickCounter >= CFG.pushEveryTicks then
      tickCounter = 0
      broadcastState()
    end
    return
  end
  -- THE GRACE, for both session kinds: once the flag is out, a driver with no
  -- crossing left to give must not hold the session open forever.
  if race.finalLap then
    race.finalLapLeft = race.finalLapLeft - CFG.tickMs / 1000.0
    if race.finalLapLeft <= 0 then
      local stranded = {}
      for _, rec in pairs(players) do
        if onTrack(rec) then stranded[#stranded + 1] = rec end
      end
      -- Snapshot first: retireDriver sends a client event per driver.
      for _, rec in ipairs(stranded) do
        retireDriver(rec, isQualiSession()
          and 'Qualifying over: the session closed before you reached the line'
          or  'Race over: the flag fell before you reached the line')
      end
      if #stranded > 0 then
        MP.SendChatMessage(-1, string.format(
          '[RaceManager] Final-lap grace expired: %d driver%s taken where they stood.',
          #stranded, #stranded == 1 and '' or 's'))
      end
      finishSession('the final-lap grace expired')
      return
    end
  elseif race.phase == 'qualifying' then
    race.qualiTime = race.qualiTime + CFG.tickMs / 1000.0
    if race.qualiTimeLimit > 0 and race.qualiTime >= race.qualiTimeLimit then
      beginFinalLap()
      -- No return: the broadcast below carries the final-lap flag.
    end
  elseif race.phase == 'racing' and race.raceTimeLimit > 0 and not race.pacing then
    if not race.raceExpired then
      -- Time up only arms the wait: the leader's next crossing starts the final
      -- lap. Measured from the GREEN (a pace lap is not race time).
      if raceElapsed() >= race.raceTimeLimit then
        race.raceExpired   = true
        race.raceExpiredAt = race.time
        broadcastState()
        MP.SendChatMessage(-1, '[RaceManager] TIME UP: the FINAL LAP starts when the '
          .. 'leader next takes the line.')
        print(string.format('[RaceManager] Timed race: %ds elapsed, waiting on the leader',
          math.floor(race.raceTimeLimit)))
      end
    elseif not race.lastLapNum
        and race.time - (race.raceExpiredAt or 0) >= CFG.finalLapGrace then
      -- No lead-lap crossing for longer than a lap should take (the leader
      -- retired, the field stopped): the flag goes out directly.
      race.finalLap     = true
      race.finalLapLeft = CFG.finalLapGrace
      broadcastState()
      MP.SendChatMessage(-1, '[RaceManager] CHECKERED FLAG: no leader crossing since the '
        .. 'clock expired. Everyone still out is classified as they cross.')
      print('[RaceManager] Timed race: no lead-lap crossing within the grace, flag out')
    end
  end
  -- The pace lap: watch the leader home and drop the green. Every tick (ten
  -- metres is under half a second at pace), and a scan, not a sort.
  if race.pacing then paceLapWatch() end
  -- The called restart, the same way, only while one is called.
  if race.restartPending then restartWatch() end
  tickCounter = tickCounter + 1
  if tickCounter >= CFG.pushEveryTicks then
    tickCounter = 0
    broadcastState()
  end
end

function RM_onPlayerJoin(pid)
  -- Session ids are recycled: a changed name on an existing record is a
  -- DIFFERENT person, so the display identity must not carry over. Only display
  -- fields are refreshed; Generate Grid purges the rest.
  pid = pidKey(pid)
  if not pid then return end
  local current = MP.GetPlayerName(pid)
  -- A name that no longer matches retires the stored identity. BEFORE
  -- ensurePlayer, or the new record would inherit it.
  identityFor(pid, current)
  local existing = players[pid]
  if existing then
    if current and current ~= existing.name then
      existing.name  = current
      existing.alias = nil
      existing.spectating = false
      -- A different person: the old roster binding is not theirs.
      if rosterUnbind then rosterUnbind(pid) end
      rememberIdentity(existing)
    end
  end
  local rec = ensurePlayer(pid)
  if not rec then return end
  -- A fresh connection is not practising, whatever a recycled id carried.
  rec.practicing, rec.practiceGhost = nil, nil
  -- Connecting is not entering: opt-in makes a new arrival a spectator, 'all'
  -- puts them in the field. NOT INTO A RUNNING SESSION (derby and drag pass
  -- included): no slot, no laps, so a ghosted bystander until the next grid.
  if sessionUnderWay() or race.derbyUnderWay() or race.dragUnderWay() then
    rec.status    = 'waiting'
    rec.bystander = true
    MP.SendChatMessage(pid, '[RaceManager] A session is already running: you are '
      .. 'a spectator until it ends, and your car is a ghost so you cannot '
      .. 'interfere with it.')
    print(string.format('[RaceManager] %s joined mid-session: bystander + ghosted',
      rec.name))
  elseif race.phase == 'qualifying' and isEntrant(rec) then
    rec.status = 'qualifying'
  else
    -- Arriving while the grid is called: a slot at the back and a Ready button.
    race.callLate(rec)
  end
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  pid = pidKey(pid)
  if not pid then return end
  -- Session ids are reused: the next holder must not inherit admin rights.
  local wasAdmin = authenticatedPlayers[pid] ~= nil
  authenticatedPlayers[pid] = nil
  -- Ids are reused, so a ghost left here would be inherited by the next holder,
  -- with nobody left to clear it.
  clearGhost(pid, 'player disconnected')
  -- The binding goes with the connection; the ENTRY and its points stay.
  if rosterUnbind then rosterUnbind(pid) end
  local rec = players[pid]
  if not rec then
    -- Non-racer admin (e.g. a spectating host) left: still refresh adminPresent.
    if wasAdmin then broadcastState() end
    return
  end
  -- The record can outlive the connection; the practice cannot.
  rec.practicing, rec.practiceGhost = nil, nil
  if onTrack(rec) or rec.status == 'gridded' then
    retireAsDnf(rec, 'DNF - Disconnected')
  elseif rec.status == 'waiting' or rec.status == 'called' then
    -- Called and never placed is never having started: no DNF for it.
    local wasCalled = rec.status == 'called'
    players[pid] = nil
    if wasCalled then race.announceIfAllReady() end
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
  -- The data folder first: the settings are in it.
  migrateToDataFolder()
  -- Then the settings, pushed into the race table seeded at load
  -- (applyConfigToRace).
  loadConfigFromDisk()
  applyConfigToRace()
  MP.RegisterEvent('RM_Login',            'RM_onLogin')
  MP.RegisterEvent('RM_Logout',           'RM_onLogout')
  MP.RegisterEvent('RM_ChangePassword',   'RM_onChangePassword')
  MP.RegisterEvent('RM_StartQualifying',  'RM_onStartQualifying')
  MP.RegisterEvent('RM_GenerateGrid',     'RM_onGenerateGrid')
  MP.RegisterEvent('RM_SetReady',         'RM_onSetReady')       -- ready check
  MP.RegisterEvent('RM_ReadyAll',         'RM_onReadyAll')
  MP.RegisterEvent('RM_SetReadyCheck',    'RM_onSetReadyCheck')
  MP.RegisterEvent('RM_SetTotalLaps',     'RM_onSetTotalLaps')
  MP.RegisterEvent('RM_SetRaceLimits',    'RM_onSetRaceLimits')
  MP.RegisterEvent('RM_SetAlias',         'RM_onSetAlias')
  MP.RegisterEvent('RM_SetNametags',      'RM_onSetNametags')
  -- Race entry (opt-in) + starting grid
  MP.RegisterEvent('RM_SetGridMode',        'RM_onSetGridMode')
  MP.RegisterEvent('RM_SetDriverGrid',      'RM_onSetDriverGrid')
  MP.RegisterEvent('RM_StartPositionCount', 'RM_onStartPositionCount')
  MP.RegisterEvent('RM_SetPointToPoint',    'RM_onSetPointToPoint')
  MP.RegisterEvent('RM_PitStop',            'RM_onPitStop')
  MP.RegisterEvent('RM_HoldPos',            'RM_onHoldPos')
  -- Qualifying session rules
  MP.RegisterEvent('RM_SetGhostQuali',    'RM_onSetGhostQuali')
  MP.RegisterEvent('RM_SetQualiLimits',   'RM_onSetQualiLimits')
  -- Module 1: vehicle reset ruleset + forced spectator reports
  MP.RegisterEvent('RM_SetMaxResets',     'RM_onSetMaxResets')
  MP.RegisterEvent('RM_SetResetMode',     'RM_onSetResetMode')
  MP.RegisterEvent('RM_VehicleReset',     'RM_onVehicleReset')
  MP.RegisterEvent('RM_ResetDenied',      'RM_onResetDenied')
  -- Reset ghosting
  MP.RegisterEvent('RM_GhostStart',       'RM_onGhostStart')
  MP.RegisterEvent('RM_GhostEnd',         'RM_onGhostEnd')
  MP.RegisterEvent('RM_GhostBlocked',     'RM_onGhostBlocked')
  -- Module 2: rallycross joker lap
  MP.RegisterEvent('RM_SetJokerEnabled',  'RM_onSetJokerEnabled')
  MP.RegisterEvent('RM_JokerLap',         'RM_onJokerLap')
  -- Module 4: garage list (vehicle & setup locking)
  MP.RegisterEvent('RM_WhitelistVehicle', 'RM_onWhitelistVehicle')
  MP.RegisterEvent('RM_ClearGarage',      'RM_onClearGarage')
  MP.RegisterEvent('RM_RemoveGarageEntry','RM_onRemoveGarageEntry')
  -- Open to everyone, like the Take button it answers.
  MP.RegisterEvent('RM_TakeGarageCar',   'RM_onTakeGarageCar')
  MP.RegisterEvent('RM_SetGarageEnforce', 'RM_onSetGarageEnforce')
  MP.RegisterEvent('RM_SetGarageMode',    'RM_onSetGarageMode')
  MP.RegisterEvent('RM_SetGarageClass',   'RM_onSetGarageClass')  -- multi-class
  MP.RegisterEvent('RM_SetGarageName',    'RM_onSetGarageName')   -- display name
  MP.RegisterEvent('RM_SaveGarageSet',    'RM_onSaveGarageSet')   -- named sets
  MP.RegisterEvent('RM_LoadGarageSet',    'RM_onLoadGarageSet')
  MP.RegisterEvent('RM_DeleteGarageSet',  'RM_onDeleteGarageSet')
  MP.RegisterEvent('RM_SetHeatDraw',      'RM_onSetHeatDraw')     -- heat seeding
  MP.RegisterEvent('RM_VehicleConfig',    'RM_onVehicleConfig')
  MP.RegisterEvent('onVehicleSpawn',      'RM_onVehicleSpawn')
  MP.RegisterEvent('onVehicleEdited',     'RM_onVehicleEdited')
  MP.RegisterEvent('RM_StartCountdown',   'RM_onStartCountdown')
  MP.RegisterEvent('RM_StartRace',        'RM_onStartRace')      -- pace-lap start
  MP.RegisterEvent('RM_SetPaceLap',       'RM_onSetPaceLap')
  MP.RegisterEvent('RM_Caution',          'RM_onCaution')        -- full-course yellow
  MP.RegisterEvent('RM_Restart',          'RM_onRestart')
  MP.RegisterEvent('RM_CancelRestart',    'RM_onCancelRestart')  -- wave the restart off
  MP.RegisterEvent('RM_SetLuckyDog',      'RM_onSetLuckyDog')    -- the free pass rule
  MP.RegisterEvent('RM_SetHeats',         'RM_onSetHeats')       -- Module 6
  MP.RegisterEvent('RM_DrawHeats',        'RM_onDrawHeats')
  MP.RegisterEvent('RM_SetHeatCurrent',   'RM_onSetHeatCurrent')
  MP.RegisterEvent('RM_EndRace',          'RM_onEndRace')
  MP.RegisterEvent('RM_ResetLeaderboard', 'RM_onResetLeaderboard')
  MP.RegisterEvent('RM_ClearResults',     'RM_onClearResults')
  MP.RegisterEvent('RM_Lap',              'RM_onLap')
  MP.RegisterEvent('RM_Progress',         'RM_onProgress')  -- live position telemetry
  MP.RegisterEvent('RM_RequestState',     'RM_onRequestState')
  MP.RegisterEvent('RM_RequestLayouts',   'RM_onRequestLayouts')
  MP.RegisterEvent('RM_SetLayoutPractice','RM_onSetLayoutPractice')
  MP.RegisterEvent('RM_PracticeEnd',      'RM_onPracticeEnd')
  MP.RegisterEvent('RM_PracticeGhost',    'RM_onPracticeGhost')
  MP.RegisterEvent('RM_SaveLayout',       'RM_onSaveLayout')
  MP.RegisterEvent('RM_LoadLayout',       'RM_onLoadLayout')
  MP.RegisterEvent('RM_DeleteLayout',     'RM_onDeleteLayout')
  MP.RegisterEvent('RM_SetFlag',          'RM_onSetFlag')
  MP.RegisterEvent('RM_SetSpectating',    'RM_onSetSpectating')
  MP.RegisterEvent('RM_Retire',           'RM_onRetire')
  MP.RegisterEvent('RM_ClearTrackState',  'RM_onClearTrackState')
  MP.RegisterEvent('RM_ClearEverything',  'RM_onClearEverything')
  -- Demo Derby module (isolated event namespace; see the DEMO DERBY section).
  MP.RegisterEvent('RM_DerbySetConfig',     'RM_onDerbySetConfig')
  MP.RegisterEvent('RM_DerbyAddMarker',     'RM_onDerbyAddMarker')
  MP.RegisterEvent('RM_DerbyClearBoundary', 'RM_onDerbyClearBoundary')
  MP.RegisterEvent('RM_DerbySetBoundaryMode', 'RM_onDerbySetBoundaryMode')
  MP.RegisterEvent('RM_DerbySetShape',      'RM_onDerbySetShape')
  MP.RegisterEvent('RM_DerbyAddStart',      'RM_onDerbyAddStart')
  MP.RegisterEvent('RM_DerbyClearStarts',   'RM_onDerbyClearStarts')
  MP.RegisterEvent('RM_DerbyMoveMarker',    'RM_onDerbyMoveMarker')
  MP.RegisterEvent('RM_DerbyRemoveMarker',  'RM_onDerbyRemoveMarker')
  MP.RegisterEvent('RM_DerbyMoveStart',     'RM_onDerbyMoveStart')
  MP.RegisterEvent('RM_DerbyRemoveStart',   'RM_onDerbyRemoveStart')
  MP.RegisterEvent('RM_DerbyVehicleReset',  'RM_onDerbyVehicleReset')
  MP.RegisterEvent('RM_DerbyResetDenied',   'RM_onDerbyResetDenied')
  MP.RegisterEvent('RM_DerbyStart',         'RM_onDerbyStart')
  MP.RegisterEvent('RM_DerbyEnd',           'RM_onDerbyEnd')
  MP.RegisterEvent('RM_DerbyDisqualified',  'RM_onDerbyDisqualified')
  MP.RegisterEvent('RM_DerbyDemolished',    'RM_onDerbyDemolished')
  MP.RegisterEvent('RM_DerbyRequestState',  'RM_onDerbyRequestState')
  MP.RegisterEvent('RM_DerbyFormUp',        'RM_onDerbyFormUp')
  MP.RegisterEvent('RM_DerbyReady',         'RM_onDerbyReady')     -- ready check
  MP.RegisterEvent('RM_DerbyReadyAll',      'RM_onDerbyReadyAll')
  -- Derby arena layouts (save/load, mirroring the track layout workflow)
  MP.RegisterEvent('RM_DerbyRequestLayouts','RM_onDerbyRequestLayouts')
  MP.RegisterEvent('RM_DerbySaveLayout',    'RM_onDerbySaveLayout')
  MP.RegisterEvent('RM_DerbyLoadLayout',    'RM_onDerbyLoadLayout')
  MP.RegisterEvent('RM_DerbyDeleteLayout',  'RM_onDerbyDeleteLayout')
  MP.RegisterEvent('RM_DerbyTick',          'RM_DerbyTick')
  -- A timer event only fires if registered (the derby countdown froze on 3).
  MP.RegisterEvent('RM_DerbyCountdownTick', 'RM_DerbyCountdownTick')
  MP.RegisterEvent('onPlayerJoin',          'RM_Derby_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',    'RM_Derby_onPlayerDisconnect')
  -- Drag racing (isolated module; see drag.lua).
  MP.RegisterEvent('RM_DragSetConfig',    'RM_onDragSetConfig')
  MP.RegisterEvent('RM_DragBuild',        'RM_onDragBuild')
  MP.RegisterEvent('RM_DragClear',        'RM_onDragClear')
  MP.RegisterEvent('RM_DragStage',        'RM_onDragStage')
  MP.RegisterEvent('RM_DragPractice',     'RM_onDragPractice')
  MP.RegisterEvent('RM_DragRun',          'RM_onDragRun')
  MP.RegisterEvent('RM_DragReady',        'RM_onDragReady')      -- ready check
  MP.RegisterEvent('RM_DragReadyAll',     'RM_onDragReadyAll')
  MP.RegisterEvent('RM_DragAbort',        'RM_onDragAbort')
  MP.RegisterEvent('RM_DragWithdraw',     'RM_onDragWithdraw')
  MP.RegisterEvent('RM_DragSetDial',      'RM_onDragSetDial')
  MP.RegisterEvent('RM_DragStaged',       'RM_onDragStaged')
  MP.RegisterEvent('RM_DragFoul',         'RM_onDragFoul')
  MP.RegisterEvent('RM_DragResult',       'RM_onDragResult')
  MP.RegisterEvent('RM_DragRequestState', 'RM_onDragRequestState')
  MP.RegisterEvent('RM_DragTick',         'RM_DragTick')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_Drag_onPlayerDisconnect')
  -- Map switching (isolated module; see maps.lua). RM_MapTick is its timer.
  MP.RegisterEvent('RM_MapRequest',       'RM_onMapRequest')
  MP.RegisterEvent('RM_MapSwitch',        'RM_onMapSwitch')
  MP.RegisterEvent('RM_MapCancel',        'RM_onMapCancel')
  MP.RegisterEvent('RM_MapVoteStart',     'RM_onMapVoteStart')
  MP.RegisterEvent('RM_MapVote',          'RM_onMapVote')
  MP.RegisterEvent('RM_MapVoteCancel',    'RM_onMapVoteCancel')
  MP.RegisterEvent('RM_MapVoteConfig',    'RM_onMapVoteConfig')
  MP.RegisterEvent('RM_MapRename',        'RM_onMapRename')
  MP.RegisterEvent('RM_MapTick',          'RM_MapTick')
  MP.RegisterEvent('onPlayerAuth',        'RM_Map_onPlayerAuth')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_Map_onPlayerDisconnect')
  -- Lap records (isolated module; see records.lua). Request is open to anyone.
  MP.RegisterEvent('RM_RecordsRequest',   'RM_onRecordsRequest')
  MP.RegisterEvent('RM_RecordsClear',     'RM_onRecordsClear')
  MP.RegisterEvent('RM_RecordsRemove',    'RM_onRecordsRemove')
  -- Cup / series points (see the CUP section).
  MP.RegisterEvent('RM_CupSetEnabled',    'RM_onCupSetEnabled')
  MP.RegisterEvent('RM_CupStart',         'RM_onCupStart')
  MP.RegisterEvent('RM_CupReset',         'RM_onCupReset')
  MP.RegisterEvent('RM_CupSetPreset',     'RM_onCupSetPreset')
  MP.RegisterEvent('RM_CupSavePreset',    'RM_onCupSavePreset')
  MP.RegisterEvent('RM_CupDeletePreset',  'RM_onCupDeletePreset')
  MP.RegisterEvent('RM_CupSetScoring',    'RM_onCupSetScoring')
  MP.RegisterEvent('RM_CupRequestState',  'RM_onCupRequestState')
  MP.RegisterEvent('RM_CupAdjust',        'RM_onCupAdjust')
  MP.RegisterEvent('RM_CupRemoveAdjust',  'RM_onCupRemoveAdjust')
  MP.RegisterEvent('RM_CupDropRound',     'RM_onCupDropRound')
  MP.RegisterEvent('RM_CupBindDriver',    'RM_onCupBindDriver')
  MP.RegisterEvent('RM_RosterAdd',        'RM_onRosterAdd')
  MP.RegisterEvent('RM_CupForgetDriver',  'RM_onCupForgetDriver')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', CFG.tickMs)
  -- Boot clean: a client connected across a reload drops its stale gates.
  clearTrackState('server startup')
  getLayouts()       -- warm the layout cache so saved tracks survive the restart visibly
  getGarage()        -- and the approved vehicle list (Module 4)
  derbyMod.getDerbyLayouts()  -- and the saved derby arenas
  rosterWarm()       -- and the display names an admin has already assigned
  cupWarm()          -- and a cup left running when the server went down
  race.dragWarm()    -- and a drag ladder left half-run when it did
  if race.mapsWarm then race.mapsWarm() end  -- and whether a map switch took
  print('[RaceManager] Server plugin loaded (build ' .. RM_BUILD
    .. ', circuit edition, map: ' .. getCurrentMap() .. ')')
end
