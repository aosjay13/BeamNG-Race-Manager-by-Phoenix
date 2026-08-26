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
-- ---------------------------------------------------------------------------
-- SERVER CONFIGURATION
-- ---------------------------------------------------------------------------
-- Every number an admin might reasonably want to change, in one table, with
-- the file that overrides it sitting beside layouts.json.
--
-- These were sixteen separate top-level constants scattered down the file, and
-- changing any of them meant editing Lua and redeploying -- which on a live
-- league means a server restart to alter the lap count. They are one object
-- now, seeded here and overridden from config.json at boot.
--
-- SEEDED, NOT LIVE. This is what a session STARTS as. An admin changing laps
-- from the panel mid-evening changes race.totalLaps, not this -- so the file
-- stays what the server comes up as, and the panel stays the way to change the
-- race in front of you.
--
-- The file is written out with these values the first time the plugin runs, so
-- there is always something on disk to edit rather than a format to guess at.
-- Assigned further down, once the JSON codec and the directory helper it needs
-- exist. Declared HERE because changing the admin password has to write the
-- file, and that handler sits two thousand lines above the writer.
-- Make this plugin's folder importable before anything requires a sibling.
--
-- BeamMP already puts it on package.path when it loads a plugin. The headless
-- test harness does not: it dofile()s this file from the repo root, so
-- require('derby') would fail there and nowhere else -- the worst place for a
-- difference between how the tests run and how the server runs.
--
-- Derived from this file's own path, so it is correct under both.
do
  -- Long-bracket string so the Windows separator needs no escaping.
  local src = debug.getinfo(1, 'S').source:sub(2):gsub([[\]], '/')
  package.path = (src:match('^(.*)/[^/]+$') or '.') .. '/?.lua;' .. package.path
end

local saveConfigToDisk

local CFG = {
  -- The admin password. It lives here so that CHANGING it survives a restart:
  -- until now the change was in memory only, so every restart quietly put the
  -- password back to 'phoenix' and nobody found out until a login failed.
  adminPassword = 'phoenix',

  -- What a race starts as.
  totalLaps     = 5,
  raceTimeLimit = 0,         -- seconds, 0 = run to a lap count instead
  maxResets     = -1,        -- -1 unlimited, 0 none, N per driver per session
  resetMode     = 'inplace', -- 'inplace' | 'checkpoint'
  nametags      = false,
  countdownFrom = 3,         -- 3, 2, 1, GO!
  endDelay      = 5,         -- seconds the results are held after the last car home

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

  -- ADVANCED. Changing these changes how the plugin behaves rather than how a
  -- race is run, and the limits exist to keep a typo from becoming a hang.
  tickMs          = 100,     -- server clock resolution
  pushEveryTicks  = 3,       -- broadcasts are one in this many ticks
  maxTotalLaps    = 500,
  maxResetLimit   = 99,
  maxQualiLaps    = 99,
  maxQualiTime    = 7200,    -- seconds (2 h)
  maxRaceTime     = 21600,   -- seconds (6 h), so an endurance race is expressible
  unlimitedResets = -1,      -- the sentinel, not a preference: do not change
}
-- Broadcast cadence while racing. This is also the live-position refresh rate:
-- every push re-sorts the running order and re-stamps each driver's position,
-- so 3 ticks (~300 ms) keeps the leaderboard lively without flooding clients.
-- League regulations. Resets: -1 means unlimited (the historical behavior and
-- the default), 0 forbids resets outright, N allows N per session.
-- Reset ghosting. A driver who resets mid-session is intangible to other cars
-- for a moment, so the car they materialise on top of is not hit by them and
-- they are not hit by anyone.
--
-- Server-side because it is a LEAGUE rule: a client running a five-second ghost
-- against a field running eight is a field where two cars disagree about whether
-- they can touch.
--
-- The maximum caps the BASE TIMER only, not the ghost. A car still sitting
-- inside another when the timer runs out stays ghosted for as long as that is
-- true, with no limit. See the occupancy check on the client, the only place
-- that can see where cars are.
-- Grid hold. The server has no physics and cannot freeze a car, but it owns the
-- hold: it judges whether each held car is where it was put and pulls back the
-- ones that are not. The tolerance absorbs a car settling onto its suspension
-- and still catches a creep off the line.
-- Forward declaration: the validator lives with the layout store far below, but
-- the grid-hold code above needs the same validation on client-reported
-- coordinates, and a second near-identical sanitizer would drift from the first.
local sanitizeCheckpoints
local sanitizeBranches

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
  -- Put a driver's display name on their BeamMP nametag as well as on the
  -- board. Off by default: it is cosmetic, it only reaches clients running
  -- this mod, and a league that has not assigned any names gains nothing
  -- from it. See RM_onSetNametags.
  nametags     = false,
  time         = 0.0,        -- seconds since GO (advanced by RM_Tick while a session runs)
  totalLaps    = CFG.totalLaps,
  maxResets    = CFG.unlimitedResets,  -- vehicle resets allowed per driver per session
  resetMode    = 'inplace',  -- what a legal reset does: 'inplace' | 'checkpoint'
  jokerEnabled = false,      -- rallycross joker lap required exactly once per race
  -- Joker gates the loaded track actually has. The joker lap cannot be armed
  -- without them: the rule disqualifies anyone who did not complete the route,
  -- and with no route that is the whole field.
  jokerGates   = 0,
  -- THE FLAG THE FIELD IS RACING UNDER: green, yellow or red.
  --
  -- RED IS A CONDITION, NOT A STATE CHANGE. It means stop, something is being
  -- cleaned up, and the session then goes yellow and back to green. Nothing is
  -- ended, nobody is frozen and no phase moves: the race is still running the
  -- whole time. That is the entire reason this is a field and not a phase.
  --
  -- Advisory: it is shown, announced and
  -- written into the results, and it polices nothing. Deciding automatically
  -- that an overtake under yellow was illegal means holding a second running
  -- order that survives the caution and reconciles on green, and a marshal who
  -- can see the incident is better at that than a distance comparison.
  --
  -- Deliberately NOT a phase. There are fifty-odd `phase ==` tests across the
  -- two Lua halves and most would be wrong by default for a new one; a separate
  -- field is read only where it is wanted.
  flag         = 'green',
  -- Race entry. 'all' (default): every connected session is a participant, so a
  -- server that never touches this setting grids everybody who is there. 'join':
  -- drivers opt in with the UI's Join Race button and only they are gridded.
  --
  -- The default is 'all' because it is the answer that fails safe. Getting it
  -- wrong under 'join' means an admin presses Generate Grid and forms a grid of
  -- nobody -- every driver on the server is left standing while the one person
  -- who could fix it works out that a button they have never needed was the
  -- problem. Getting it wrong under 'all' means somebody who wanted to watch is
  -- put on the grid, which they undo with one press of Leave. The demo derby
  -- has defaulted to 'all' since it was written; this is the racing side
  -- agreeing with it.
  -- Starting grid. gridMode decides how the slots are filled:
  --   quali   -- fastest qualifying lap first (the classic behavior)
  --   reverse -- slowest qualifying lap first, so the fastest starts last
  --   random  -- a random draw, for when no qualifying was run
  --   custom  -- the order the admin set by hand (RM_SetDriverGrid)
  gridMode     = 'quali',
  startSlots   = 0,          -- start positions the loaded track layout has
  -- Is the loaded track a sprint stage rather than a circuit? A point-to-point
  -- run is driven ONCE, first gate to last, and the last gate is a finish
  -- rather than a line crossed again. Setting a circuit to one lap times the
  -- same thing, which is why that was the workaround -- but it reads as a
  -- one-lap circuit everywhere, and this is the difference being made explicit.
  -- It belongs to the track, so it arrives with the layout.
  pointToPoint = false,
  -- BRANCH GATES. Another way through a checkpoint that already exists: slot i is
  -- cleared by crossing the main gate OR any branch gate authored against slot i.
  -- A branch gate never adds a slot, which is the whole reason the running order
  -- below needs no changes at all -- cpCleared means the same thing whichever
  -- gates a driver took, and nothing here has to know which.
  --
  -- Held here only to be validated, persisted and handed back out: the server has
  -- no physics and never tests a crossing. Shape:
  --   { { slot = 1, x, y, z, hx, hy, width?, height?, oneWay? }, ... }
  branches     = {},
  -- THE LOADED LAYOUT ITSELF, kept so it can be sent again.
  --
  -- It used to be broadcast once, at the moment an admin pressed Load, and never
  -- again -- so it reached exactly the people who were already connected. Anyone
  -- who joined afterwards had no gates at all, and the workaround was for the
  -- admin to wait until the whole field had spawned before loading. A track is
  -- state, not an announcement.
  layout       = nil,
  -- Slots in a lap on the loaded track, or 0 when no layout came through this
  -- server. Used only to clamp reported progress (see RM_onProgress).
  slotCount    = 0,
  -- Does this track grid its cars somewhere other than the start/finish line? A
  -- head-on layout has to -- two directions cannot share one row of slots -- and
  -- then the run from the grid to the first crossing is a part lap that must not
  -- be timed. See outLapOwed.
  gridOffLine  = false,
  -- THE HOLD AT THE FLAG. `endsAt` is the race.time the session actually closes
  -- at, or nil when nothing has armed it; `endDelay` is how long that hold is.
  --
  -- The derby has had one of these since it was built (derby.endDelay). A race
  -- ended on the spot, which meant the tick the last car crossed the line was
  -- the tick every ghost lifted and every finished driver got their collisions
  -- back, with nobody given a moment to see any of it.
  --
  -- ON THE TABLE RATHER THAN AS A CONSTANT, and that is not a style choice: the
  -- top level of this file is a function and Lua allows it 200 locals, which
  -- this chunk is close enough to that adding two named ones pushed it over and
  -- the file silently failed to compile. Same reason the derby keeps its own
  -- here. Set endDelay to 0 to close the session the instant the field is home.
  endsAt       = nil,
  endReason    = nil,
  endDelay     = 5,
  -- WHERE those start positions are: { x, y, z, hx, hy } per slot, slot 1 first.
  -- Reported by a client when a track is loaded or edited, and set directly when
  -- a saved layout is loaded. The count above is enough to warn that a field is
  -- bigger than its grid; policing the hold needs the coordinates. The heading is
  -- what splits a head-on field, and it is the client that reads it.
  startPositions = {},
  -- Qualifying session rules.
  ghostQuali     = false,    -- rivals are ghosts during qualifying
  -- qualiLapLimit counts TIMED laps, which is not the same as crossings: every
  -- driver owes an OUT LAP first (see qualiOutLap below), so a 3 lap session is
  -- four trips past the line and three times that can go on the board.
  qualiLapLimit  = 0,        -- timed laps allowed per driver (0 = unlimited)
  qualiTimeLimit = 0,        -- seconds the session runs for (0 = unlimited)
  qualiTime      = 0.0,      -- seconds elapsed in the current quali session
  -- Did the qualifying session that produced the times on the board give an out
  -- lap away? A RECORD of what was run, not the rule: the results file is
  -- written at the end of the RACE, by which point the live rule reads 'race'
  -- and the track underneath may even have been swapped. The file has to
  -- describe the session the times came from.
  qualiOutLapRun = false,
  -- The same record for a race that gave one away (see race.gridOffLine).
  raceOutLapRun  = false,
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
  -- Fastest lap of the session so far, and who set it. Kept incrementally as
  -- laps are scored rather than derived by scanning the field on every
  -- broadcast: a lap arrives a handful of times a minute, a broadcast goes out
  -- three times a second.
  bestLapTime    = nil,
  bestLapPid     = nil,
  finalLap       = false,
  finalLapLeft   = 0,        -- seconds of grace left before the stragglers are
                             -- taken where they stand (see FINAL_LAP_GRACE)

  -- ---------------------------------------------------------------------
  -- TIMED RACES: "10 minutes + 1 lap"
  -- ---------------------------------------------------------------------
  -- A race runs to a lap count OR to a clock, never both (raceTimeLimit > 0
  -- makes totalLaps inert - see sessionLapTarget). The clock does not end the
  -- race when it expires, which is the whole point of the format: the race ends
  -- one lap after the LEADER next takes the line.
  --
  -- Three states, in order, and each needs its own flag because the answer to
  -- "is this crossing your last" is different in each:
  --
  --   raceExpired  the clock is out. Nothing changes for anybody yet: whoever
  --                is leading has to reach the line first. A driver reading
  --                "laps to go" sees TWO at this point - finish this one, then
  --                run the last.
  --   lastLapNum   the leader has crossed, and that crossing set the number of
  --                the final lap. Completing THAT lap is what ends a driver's
  --                race, so a car two seconds behind the leader still gets a
  --                full lap rather than being flagged off at the line.
  --   finalLap     the leader has finished. From here the checkered flag is
  --                out and the NEXT crossing is terminal for everyone still
  --                running, which is how lapped cars are classified. This is
  --                the flag qualifying has always used and it means exactly the
  --                same thing here.
  -- WHICH LIMITS ARE LIVE, named rather than inferred from which numbers are
  -- non-zero. Endurance needs both of them at once, so "raceTimeLimit > 0 means
  -- the laps are inert" stopped being a safe reading the moment it existed.
  --
  --   'laps'       a fixed distance. raceTimeLimit is held at 0.
  --   'timed'      a clock plus one lap. totalLaps is remembered but inert.
  --   'endurance'  BOTH, whichever comes first: the distance, or the clock
  --                plus one lap. This is the only mode where reaching the lap
  --                target ends the race for everybody rather than only for the
  --                driver who reached it - see RM_onLap.
  raceMode       = 'laps',
  raceTimeLimit  = CFG.raceTimeLimit,
  raceExpired    = false,    -- clock out, waiting on the leader
  raceExpiredAt  = nil,      -- race.time it expired, for the stuck-field valve
  lastLapNum     = nil,      -- the lap number that is the final one
}
local players = {}          -- [playerID] = per-player record
-- Authoritative reset-ghost state: [playerID] = { startedAt, duration }, both on
-- race.time. Held here and not only on the clients that happened to be listening
-- so that a driver joining or reconnecting DURING a ghost is told about it --
-- otherwise their client shows a solid car that everyone else is passing
-- through, and they are the one person who can drive into it.
--
-- A table keyed by player and not a flag: simultaneous ghosts are independent,
-- and one ending must never end another.
local ghosts = {}
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'
local lapFirsts = {}        -- [lapNumber] = pid of the first driver to complete that lap

-- Empty a table WITHOUT replacing it.
--
-- `players = {}` reads as "start again" and mostly behaves that way, but it
-- swaps the table for a new one and leaves every existing reference pointing at
-- the old contents. Nothing was holding one when this was written, which is why
-- it was fine; a module that captures host state once at init IS such a holder,
-- and a session reset would quietly leave it reading a table nobody else
-- updates any more.
--
-- Clearing in place keeps one identity for the life of the process, so a
-- reference taken at startup is still the right table after any number of
-- resets. Same visible behavior, one fewer way to go wrong later.
local function wipe(t)
  for k in pairs(t) do t[k] = nil end
  return t
end
-- How long a timed session waits, after the clock expires, for drivers still out
-- there to come round and take the flag. A driver sitting in the pits, parked,
-- or who never left the grid has no crossing to give, and without a bound the
-- session would wait for them forever. Sized to comfortably clear one lap of a
-- long circuit; when it runs out the stragglers are taken where they stand and
-- the session closes normally.

-- Does the session now running open with an OUT LAP -- one trip past the line
-- that is neither timed nor scored nor counted against the lap allowance?
--
-- Qualifying starts from a standing grid, so the first crossing measures a
-- launch rather than a lap, and on a track with a slow first corner it is a time
-- nobody can beat later for reasons that have nothing to do with pace. It is
-- counted SEPARATELY from the allowance, so three qualifying laps still means
-- three timed laps.
--
-- A sprint stage is the exception and has to be: a point-to-point run is driven
-- once, so a lap given away is the session given away, and there is no line to
-- come back past.
--
-- A RACE owes one whenever the track says its grid is not on the line. Same
-- problem, not a qualifying rule in disguise: a lap is only a lap if it starts
-- where it ends. Grid the field around the circuit, which a head-on layout must,
-- and the run to the first crossing is a fraction of a lap that would take
-- fastest lap off every honest one.
--
-- It belongs to the TRACK, so it travels with the layout (race.gridOffLine)
-- rather than being a switch an admin has to remember on the night.
local function outLapOwed()
  -- A sprint stage never owes one: it is driven once, first gate to last, so a
  -- lap given away is the whole session given away.
  if race.pointToPoint then return false end
  return race.sessionKind == 'quali' or race.gridOffLine == true
end


-- NOTHING HERE KNOWS WHICH WAY ROUND A DRIVER IS GOING, and nothing needs to.
--
-- A branch gate is another way through a checkpoint rather than a line a driver
-- is on, so clearing CP 3 means the same thing for the whole field however they
-- reached it. The server counts checkpoints cleared, which is exactly what it
-- counted before branch gates existed. There is no lane to assign at the grid,
-- none to carry on a record, and none to name in the results.

-- ---------------------------------------------------------------------------
-- Admin authentication
-- ---------------------------------------------------------------------------
-- BeamMP guest account IDs rotate constantly, so admin rights are gated by a
-- shared password rather than a name/ID whitelist. A player sends RM_Login with
-- the current master password; on a match their session ID is recorded in
-- authenticatedPlayers and every admin-level event checks that table before
-- acting. The default below is meant to be rotated on the fly (RM_ChangePassword)
-- once an admin is logged in -- change it before the first public session.
local adminPassword = CFG.adminPassword
local authenticatedPlayers = {}   -- [playerID] = true while that session is an admin

local function isAuthenticated(pid)
  return authenticatedPlayers[pid] == true
end

-- Guard placed at the top of every admin-level event handler. Any command from
-- a session that has not logged in is dropped (and logged so it's diagnosable).
-- A REFUSAL HAS TO REACH THE CLIENT, not just the log.
--
-- The client caches its own admin flag on purpose, so it survives the pause
-- menu, and `youAreAdmin` only rides targeted replies. Nothing else tells it the
-- server dropped that flag. Session ids are REUSED, so a reconnect clears the
-- auth here while the panel goes on showing admin controls that silently do
-- nothing: every button dead, no error anywhere, and logging out and back in
-- the only cure anybody could stumble onto.
--
-- So the refusal is answered. The client corrects its flag, the panel offers the
-- login again, and a dead button becomes a sentence.
local function requireAuth(pid)
  if authenticatedPlayers[pid] then return true end
  print('[RaceManager] Ignored admin command from unauthenticated player ' .. tostring(pid))
  MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({
    success = false, lapsed = true,
  }))
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
    -- SELF-DECLARED SPECTATOR, and the only thing that takes a driver out of the
    -- field. Everyone connected races unless this is set. Durable: it is mirrored
    -- into the identity registry so it survives the online purge.
    spectating = false,
    gridPos    = nil,        -- locked-in starting position (Generate Grid)
    customGrid = nil,        -- slot the admin pinned this driver to (custom mode)
    qualiBest  = nil,        -- best qualifying lap (seconds)
    qualiLaps  = 0,          -- timed qualifying laps completed this session
    -- This driver still owes the out lap: their next crossing is the one that
    -- starts their timing rather than one that records anything. Per driver and
    -- not a session-wide flag, because the field is spread around the circuit --
    -- one driver can be two flying laps in while another is still on their out
    -- lap, and each of them has to be told the truth about their own lap.
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
    -- Connected while a session was already running: not a participant, and
    -- ghosted for everyone until the next grid forms. See RM_onPlayerJoin.
    bystander  = nil,
    outReason  = nil,        -- why this driver is dnf/dsq (results + UI text)
    -- The place this driver was running in at the moment they retired.
    --
    -- Kept because the live order does NOT keep it: a driver who stops is sorted
    -- to the bottom of the table on the very next broadcast, and `position` is
    -- overwritten with where they ended up rather than where they were. That is
    -- right for a leaderboard of who is still racing and wrong for a record of
    -- what happened -- a driver who was second when their engine let go was
    -- second, whatever the reason they stopped.
    dnfPos     = nil,      -- where a retirement CLASSIFIES: behind the field
    heldPos    = nil,      -- the place it was running in when it stopped
    -- Live position tracking (see the "Running order" section below).
    position   = nil,        -- current place in the running order (1 = leader)
    cpCleared  = 0,          -- checkpoints passed on the current lap
    distNext   = nil,        -- meters from the car to the next checkpoint center
    -- Split timing: [lap][checkpoint] = race.time when this driver reached it,
    -- and the last point stamped. What the gap and interval are subtracted from.
    splits     = nil,        -- built lazily by progress.record
    splitLap   = nil,
    splitCp    = nil,
    -- Seconds behind the leader, and behind the car directly ahead, both
    -- measured at THIS driver's last checkpoint. Recomputed per broadcast in
    -- assignPositions; nil whenever there is nothing honest to say.
    gap        = nil,
    intv       = nil,
    -- Module 4: the last vehicle configuration this client declared, and the
    -- ruling on it. Recorded whether or not the Garage List is being enforced,
    -- so switching enforcement on can audit the grid straight away instead of
    -- waiting for every client's next poll.
    --
    -- carOk is deliberately THREE-VALUED: true approved, false not on the list,
    -- nil nothing to say (not enforcing, or no declaration seen yet). A driver
    -- who has not reported must not read as an offender.
    carOk       = nil,
    carSig      = nil,   -- model + parts + tuning
    carPartsSig = nil,   -- model + parts, the half 'parts' mode matches on
    carLabel    = nil,   -- what to call it in the audit
    carGame     = nil,   -- BeamNG build, for the version-skew message
  }
end

-- ---------------------------------------------------------------------------
-- Live progress: the checkpoint telemetry, and the splits built out of it
-- ---------------------------------------------------------------------------
-- ONE TABLE HOLDING TWO FUNCTIONS, and that is not stylistic. This chunk sits on
-- Lua's 200-active-locals ceiling -- see the note in ARCHITECTURE.md about why
-- the roster and the cup live inside an installer function -- and going over it
-- does not warn: the file simply stops compiling and the whole plugin is gone.
-- Adding the split recorder below as a local of its own was the name that went
-- over. One table replacing the one local that was already here costs no new
-- slot at all, and the two functions belong together anyway: both are about
-- where a driver has got to.
local progress = {}

-- Telemetry reported by a client is only meaningful while that driver is
-- circulating; wipe it whenever their lap state restarts so a stale distance
-- can never decide a position.
--
-- THE SPLITS ARE NOT WIPED HERE. This runs on every lap crossing, and a split
-- table emptied once a lap is a gap column that blanks itself every time
-- anybody crosses the line. Splits belong to the SESSION and are cleared where
-- the session is: the grid, and GO.
function progress.clear(rec)
  rec.cpCleared = 0
  rec.distNext  = nil
end

-- ---------------------------------------------------------------------------
-- Split timing: when each driver reached each checkpoint
-- ---------------------------------------------------------------------------
-- What a gap to the leader is made of, and the only honest way to build one
-- here. The running order is ranked on laps, then checkpoints cleared, then
-- meters to the next gate, and not one of those converts into seconds behind --
-- but "you reached checkpoint 7 of lap 3 at 214.6s, the leader reached it at
-- 212.1s" is a subtraction with nothing estimated in it.
--
-- ONE CLOCK MAKES IT WORK. race.time is the server's and everybody is scored on
-- it already, so two drivers' stamps are directly comparable without any clock
-- sync between clients.
--
-- IT IS ALSO IMMUNE TO BRANCH GATES, which a distance-based gap would not be. A
-- branch gate is another way through a checkpoint that already exists, so two
-- cars at opposite ends of a head-on oval have cleared the same checkpoints and
-- their splits compare exactly. Nothing here knows or cares which gate anybody
-- took -- the same property that lets the leaderboard rank them at all.
--
-- Nested per lap rather than flattened into one key, so the structure needs no
-- knowledge of how many checkpoints a lap has. The server does not always have
-- that: race.slotCount is 0 for a route built in the editor and never saved as
-- a layout, and a stride guessed from a scalar would silently collide.
--
-- BACKFILLED ON A JUMP, which is the part that is not obvious. The arithmetic
-- looks the LEADER up at the FOLLOWER's last checkpoint, so a single hole in the
-- leader's table blanks the gap column for everyone behind them. Reports do go
-- missing: the client fires one on the frame after every crossing (checkGates
-- sets progressLeft = 0 for exactly that reason), but a dropped packet leaves a
-- gap in the sequence. A driver reporting checkpoint 4 when we last saw 2
-- provably passed 3 no later than now, so 3 is stamped with the same time
-- instead of being left as a hole.
function progress.record(rec, lap, cp)
  if not rec.splits then rec.splits = {} end
  local onLap = rec.splits[lap]
  if not onLap then onLap = {}; rec.splits[lap] = onLap end
  onLap[cp] = race.time
  -- Where this driver has got to, kept explicitly rather than read back off
  -- currentLap/cpCleared. Those two disagree with it exactly once, and it is the
  -- case that matters most: a finisher's currentLap is left where it was while
  -- their last split is the flag.
  rec.splitLap, rec.splitCp = lap, cp
  -- Backwards from here and no further than the start of this lap. An earlier
  -- lap is complete by definition, and a hole in one is not this crossing's
  -- business to invent a time for.
  for k = cp - 1, 0, -1 do
    if onLap[k] then break end
    onLap[k] = race.time
  end
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
local identities = {}   -- [pid] = { name = <guest name>, alias = ..., spectating = bool }

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
    spectating = rec.spectating == true,
  }
end

-- Put the whole field back in. Reset Session is the "start the evening again"
-- button, and the evening starts with everyone racing, so it clears every
-- sit-out decision. The display names do NOT go with it: an admin who spent
-- five minutes naming a grid should not have to do it twice because they
-- cleared a leaderboard.
--
-- Both halves, because they can disagree: the record is what the next grid
-- reads and the registry is what survives the online purge.
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
    -- A fresh record for a connection we already know inherits its display name
    -- and its entry decision. This is the whole point of the registry: the
    -- record is disposable, the identity is not.
    local ident = identityFor(pid, rec.name)
    if ident then
      rec.alias  = ident.alias
      rec.spectating = ident.spectating == true
    end
    players[pid] = rec
    rememberIdentity(rec)
  end
  return players[pid]
end

-- Forward declaration: the derby module lives further down the file, but its
-- entrant count is DERIVED from the racing entry list below (a driver who is
-- spectating sits out both modes). So anything that changes who is entered has to
-- refresh the derby panel too, or an admin watching it reads a stale field size
-- and presses Start Derby expecting a different set of drivers. Same pattern
-- the garage store uses to be reachable from the state broadcast above it.
local derbyEntryListChanged
-- "Is a derby running right now?", asked by the RACING side.
--
-- One boolean, assigned inside the derby block, so the racing code can refuse to
-- enter somebody into a session that is already under way without reaching into
-- derby state to find out. The isolation the two modules keep from each other is
-- the reason this is a named function rather than a peek at derby.phase.
--
-- Hung off `race` rather than given a local of its own, for the register budget
-- documented in ARCHITECTURE.md.
race.derbyUnderWay = function () return false end

-- Forward declarations for the two modules at the bottom of this file. Both
-- need the JSON codec and the layout directory, which are defined far below the
-- code that has to reach them -- the same reason garageSnapshot and formGrid are
-- declared up here and assigned further down.
--
--   rosterRemember(rec)   a driver was given a display name: bind them to their
--                         roster entry, creating it if this is a new name
--   rosterUnbind(pid)     their display name was cleared, or they left
--   rosterEntryFor(rec)   the roster entry a driver is bound to, or nil
--
-- There is deliberately NO "recognize this driver automatically" here. BeamMP
-- issues a fresh random guest name on every join, so a name proves nothing
-- about who is behind it: matching on one would usually fail to spot a
-- returning driver, and would occasionally hand a stranger somebody else's
-- identity and the championship points attached to it. Binding a connection to
-- a roster entry is an admin's decision, and only an admin's.
--   cupOnSessionComplete  a session finished: score it into the cup, if one is
--                         running. Called from finishSession and nowhere else.
--   cupOnDerbyComplete    the same for a demo derby, called from finishDerby.
--                         Takes the finished classification as an argument
--                         rather than reading derbyPlayers, so the cup never
--                         reaches into the derby module's tables and the derby
--                         module hands over a result instead of exposing state.
--   cupResultsLines       the round just banked, as text lines for the results
--                         file. The traffic goes the other way here -- results
--                         asking the cup, rather than the cup being told -- and
--                         it is still a read of a finished round, after the
--                         cars have stopped. It returns nil when no cup is
--                         running, which is what keeps a plain race night's
--                         results file byte-for-byte what it always was.
local rosterRemember, rosterUnbind, rosterEntryFor
local rosterBindTo, rosterList, rosterForget
local cupOnSessionComplete, cupOnDerbyComplete, cupResultsLines
-- Boot-time cache warm for the two, called from onInit. They exist because both
-- modules are wrapped in a `do ... end` block: Lua allows 200 locals per
-- function and this chunk was already close to it, so everything those modules
-- need internally is scoped to the block and released at its end. Only the
-- handful of names declared here cross the boundary -- which is the isolation
-- those sections claim, made structural rather than promised.
local rosterWarm, cupWarm

-- ---------------------------------------------------------------------------
-- Race entry list
-- ---------------------------------------------------------------------------
-- Nothing below assumes "connected == racing". A driver is a participant when
-- they opted in, or when the admin put the server in 'all' mode (which is what
-- the plugin used to do implicitly for everyone).
-- EVERYONE RACES UNLESS THEY SAY OTHERWISE, and that is the whole rule.
--
-- There used to be two overlapping ones: an admin picked "everyone races" or
-- "opt-in", and under opt-in each driver pressed Join Race. Then spectating
-- arrived and made a third answer to the same question, so a player could be
-- joined AND spectating and the panel had to explain which won.
--
-- Spectating is the only switch now. It covers what opt-in was for -- a one on
-- one where two people race and the rest watch is two entrants and everybody
-- else pressing Spectate -- without an admin having to set a mode first.
local function isEntrant(rec)
  if not rec then return false end
  return not rec.spectating
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
--   3. Distance to the next  -- meters from the car to the next checkpoint's
--      checkpoint               center, measured client-side (the server has no
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
-- Positions, and the two time deltas that hang off them.
--
-- GAP is seconds behind the leader; INTERVAL is seconds behind the car directly
-- ahead. Both are measured at THIS driver's own last checkpoint -- the last
-- point on track that they and the car they are being compared against have
-- both actually reached -- which is what makes them a subtraction of two
-- readings off one clock rather than an estimate.
--
-- IT COSTS THE WALK IT WAS ALREADY MAKING. Two table lookups and two
-- subtractions per driver, inside the loop that stamps `position`, on an array
-- that has just been sorted anyway. Nothing scans the field, nothing allocates,
-- and the wire grows by two numbers per row.
--
-- NOT IN QUALIFYING. There the classification is the best LAP, not time on
-- track, so a delta off the session clock says nothing about who is quicker --
-- two drivers who set identical laps ten minutes apart are level. The panel
-- computes the qualifying gap from the best laps it is already sent.
-- On the `progress` table for the reason everything else here is: a local of
-- its own is a slot this chunk does not have.
function progress.delta(other, lap, cp, mine)
  if not other or other.splits == nil then return nil end
  local theirs = other.splits[lap]
  theirs = theirs and theirs[cp]
  if not theirs then return nil end
  local d = mine - theirs
  -- NEGATIVE IS CLAMPED, not sent. It means the order has changed since this
  -- driver's last checkpoint: they were ahead when they passed it and have been
  -- overtaken between there and here. Real timing has the same artefact between
  -- splits, and "0.0" reads as too close to call, which is exactly what it is.
  -- A minus sign in a column headed "behind" reads as a bug.
  if d < 0 then d = 0 end
  -- Three decimals is past what this method can resolve (the stamp carries the
  -- reporting client's ping), and it keeps a full field's worth of floats out of
  -- a payload that goes out three times a second.
  return math.floor(d * 1000 + 0.5) / 1000
end

local function assignPositions(list)
  local leader = list[1]
  local quali  = race.sessionKind == 'quali'
  for i, rec in ipairs(list) do
    rec.position = i
    rec.gap, rec.intv = nil, nil
    -- A retirement or a disqualification has no meaningful distance to anybody:
    -- they are classified by ruling rather than by where they got to.
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
  return list
end

-- The driver fields that actually go over the wire.
--
-- A player record carries a good deal that only this file ever reads: pit and
-- grid-hold audit counters, the hold rate-limiter's timestamp, and distNext,
-- which exists so the comparator above can order two cars on the same lap.
-- None of it is rendered anywhere, and all of it was
-- being serialised for twenty drivers, three times a second, for the length of
-- a race -- then parsed again by every client that received it.
--
-- Sending what is read instead of everything that exists cuts roughly a fifth
-- off the busiest message this plugin produces. That is bandwidth on a
-- home-hosted server and JSON parsing on whatever machine a driver is running,
-- which is where it matters most.
--
-- ANY field the UI reads off a driver row must be listed here or it silently
-- becomes nil in the app; tests/ui_bindings_test.lua checks the template
-- against this list so that cannot happen quietly.
local DRIVER_WIRE_FIELDS = {
  'id', 'name', 'alias', 'status', 'spectating',
  'gridPos', 'customGrid', 'position',
  'qualiBest', 'qualiLaps', 'outLap', 'raceBest', 'currentLap', 'lapsLed', 'cpCleared',
  'finishTime', 'resets', 'resetsBlocked',
  'jokerTaken', 'jokerLap', 'outReason', 'dnfPos', 'heldPos', 'bystander',
  -- Seconds behind the leader and behind the car ahead. Two numbers, and the
  -- panel does no arithmetic on them beyond formatting.
  'gap', 'intv',
  -- Garage List verdict. Three-valued (see newRecord): the panel paints a mark
  -- for true and false and nothing at all for nil.
  'carOk',
}

-- Projection buffers are kept ON the record and reused, so a broadcast costs no
-- allocations at all: the whole point of trimming the payload is to do less
-- work, and churning twenty short-lived tables three times a second to save
-- bandwidth would be trading one cost for another.
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
    -- Race order: finished first (by finish time), then the live running order
    -- (laps > checkpoints > distance to the next checkpoint), then excluded
    -- (joker ruling) drivers, DNFs last.
    table.sort(list, raceOrderLess)
  end
  -- Positions are stamped on the REAL records, not on the projections: the rest
  -- of this file reads rec.position (retireAsDnf snapshots it, among others),
  -- and a number written only onto a copy that is thrown away after encoding
  -- would leave every one of those readers looking at a stale value.
  assignPositions(list)
  -- The array clients receive is already sorted leader-first, and every driver
  -- carries the matching position integer.
  local wire = {}
  for i = 1, #list do wire[i] = driverForWire(list[i]) end
  return wire
end

-- Forward declaration: the garage store lives further down the file (its own
-- module), but the state broadcast has to advertise the approved car list.
local garageSnapshot
-- Same arrangement, for the other direction: the countdown (far above the
-- garage code) has to be able to ask who is starting a race in a car that is
-- not on the list, and saveGarageToDisk (above the matcher) has to be able to
-- re-judge the field when the list underneath it moves.
local garageAudit
local garageRejudge

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
-- Bump this in ALL FIVE places on EVERY change that needs redeploying -- not
-- just ones that change the client/server contract. That narrower rule is what
-- let two client-side fixes ship under one stamp: the build line read as
-- matching while a client was a fix behind, which is precisely the situation
-- this was added to make visible. The five are:
--
--   server/RaceManager/main.lua          RM_BUILD   (here)
--   lua/ge/extensions/raceManager.lua    RM_BUILD
--   ui/modules/apps/RaceManager/app.js   APP_BUILD
--   ui/modules/apps/RaceManager/app.json version
--   tools/deploy.py                      RELEASE_NAME
--
-- The fifth was outside the check until 0.9.1 and duly went stale: the build
-- was produced as RaceManager-v0.9.0.zip from a 0.9.1 tree, which is precisely
-- the disagreement the stamp exists to prevent.
--
-- tests/wiring_test.lua fails if they disagree, so this is checked rather than
-- remembered.
--
-- The stamp IS the released package version, and deliberately so: it used to run
-- on a scheme of its own (3.x.y) while releases were tagged v0.x.y, and app.json
-- carried a third number that tracked neither. A driver reporting "I'm on 3.5.5"
-- meant nothing to anyone reading a release page. One number now, matching the
-- git tag the package is published under, so any redeploy needs a version bump
-- by definition.
local RM_BUILD = '0.9.8'

-- The live ghost roster as the wire carries it. Absolute END times on race.time
-- rather than "seconds left", so a client that receives this late works out a
-- SHORTER remainder instead of a longer one, and two clients on different pings
-- still agree on the instant the fade completes.
local function ghostRoster()
  local list = {}
  for pid, g in pairs(ghosts) do
    list[#list + 1] = { pid = pid, endsAt = g.startedAt + g.duration }
  end
  return list
end

-- WHO IS OUT OF THIS RACE BUT STILL ON THE MAP: the finished-driver ghost list.
--
-- Taking the flag no longer deletes the car. It stays where it is with its
-- collisions off, so a driver can go on driving it and watch the rest of the
-- race without being able to touch anyone still in it. This is the list every
-- client ghosts, and it carries player ids for the same reason the reset roster
-- does: a vehicle id is a local scene-object id and means nothing anywhere else.
--
-- AUTHORITATIVE, not an event. A pid absent from this list has no finished
-- ghost, which is what makes a missed packet, a late join and a disconnect all
-- self-correct: the client walks what it applied and drops anything no longer
-- named here.
--
-- DNF and DSQ are in it too. They are as out of the race as a finisher is, and
-- leaving a retired car solid on the racing line would put back the obstacle
-- this whole change removes.
--
-- Only while a session is actually running. Once it is over the list empties and
-- every client hands the collisions back, which is the un-ghost at the flag.
--
-- QUALIFYING COUNTS, and leaving it out was a hole rather than a decision. A
-- driver who has used their lap allowance is retired exactly the way a finisher
-- is -- status 'finished', spectator lock, car kept -- but this list was empty
-- outside a race, so their car stayed SOLID while everybody else was still on a
-- hot lap. A parked or cruising car on the racing line is worse in qualifying
-- than in a race: there is no pack to hide in and the whole session is single
-- laps that a single contact ruins.
--
-- 'countdown' is in the list for the race's sake and does no harm here;
-- qualifying reaches 'qualifying' directly from the grid.
local function finishedRoster()
  local list = {}
  if race.phase ~= 'racing' and race.phase ~= 'countdown'
     and race.phase ~= 'qualifying' then return list end
  for _, rec in pairs(players) do
    local st = rec.status
    if st == 'finished' or st == 'dnf' or st == 'dsq' then
      list[#list + 1] = rec.id
    end
  end
  return list
end

-- The client applies its own ghost the instant the reset fires and tells the
-- server afterwards. That order is deliberate and is not negotiable: the frame
-- the car lands on somebody is the frame it must already be intangible, and a
-- round trip here takes longer than that. So none of this is permission -- it is
-- the record, and the relay that gets every OTHER client ghosting the same car.
--
-- What the server adds is the part no client can do: one clock, one copy of the
-- truth for late joiners, and a log of every ghost.
local function broadcastGhost(pid, g)
  MP.TriggerClientEvent(-1, 'RM_Ghost', Util.JsonEncode({
    pid       = pid,
    active    = g ~= nil,
    startedAt = g and g.startedAt or nil,
    duration  = g and g.duration or nil,
  }))
end

-- Drop one player's ghost and tell everyone. Safe to call for a player who has
-- none, which is what makes it usable from every teardown path without each of
-- them having to check first.
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

-- Every ghost dropped at once: a session ending, a grid forming, a leaderboard
-- reset. Nothing stays ghosted across a session boundary -- the next session
-- starts with everybody solid.
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
  local garageInfo = garageSnapshot and garageSnapshot() or {}
  -- Per-player admin status. Only meaningful on a TARGETED send -- the global
  -- broadcast is one payload for everybody, so this key is left off there and
  -- clients ignore it when absent. This is what makes RM_RequestState (which
  -- the UI app sends every time it mounts) an authoritative answer to "am I
  -- still logged in", instead of the client having to remember on its own.
  local selfAdmin = nil
  local selfSpectating = nil
  if targetPid then
    selfAdmin = isAuthenticated(targetPid)
    local selfRec = players[pidKey(targetPid)]
    -- NOT `selfRec and selfRec.spectating == true or nil`. That idiom cannot
    -- return false: the `or` swallows it and yields nil, the field drops out of
    -- the JSON, and the panel's "is it a boolean" guard keeps the last value it
    -- saw. Spectating ON could be sent and spectating OFF could not, so a driver
    -- rejoined the field and the panel went on telling them they had not.
    if selfRec then selfSpectating = selfRec.spectating == true end
  end
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
    -- "Are YOU sitting this one out" (targeted sends only, like youAreAdmin).
    youSpectating = selfSpectating,
    entrants     = entrantCount(),
    gridMode     = race.gridMode,
    startSlots   = race.startSlots,
    pointToPoint = race.pointToPoint,
    -- Branch gates: whether this track has any, and whether its grid gives an out
    -- lap away. The gates themselves ride with the layout (RM_ApplyLayout) exactly
    -- as the joker route's do -- this is the part the UI needs on every tick, to
    -- label a track that has other ways through its checkpoints.
    hasBranches  = #race.branches > 0,
    gridOffLine  = race.gridOffLine,
    -- So the panel can gray the joker toggle out and say why, rather than
    -- offering a switch the server is going to refuse.
    jokerGates   = race.jokerGates,
    flag         = race.flag,
    -- Fastest lap of the session: whose row the leaderboard paints gold, and
    -- how quick it was. One driver id on a payload that already goes out.
    bestLapPid   = race.bestLapPid,
    bestLapTime  = race.bestLapTime,
    -- Reset ghosting: the rules every client must run, and who is a ghost right
    -- now. The roster rides on the state broadcast for the same reason finalLap
    -- does -- it is what a client that joined mid-ghost needs, and a one-shot
    -- event it was not connected for can never give it.
    ghostOnReset = CFG.ghostOnReset,
    ghostMinSec  = CFG.ghostMinSeconds,
    ghostMaxSec  = CFG.ghostMaxSeconds,
    ghosts       = ghostRoster(),
    ghostFinished = finishedRoster(),
    -- Qualifying rules and clock.
    ghostQuali     = race.ghostQuali,
    -- Whether this session opens with an out lap, so a client can say so before
    -- the driver has crossed anything -- and can stop saying it on the sprint
    -- stage that has none. The per-driver half of this rides on the driver rows
    -- (`outLap`), because who is still owing one is a per-driver question.
    --
    -- The name is historical: this used to be a qualifying-only rule, and a RACE
    -- on a track that grids its cars away from the start/finish line owes one for
    -- exactly the same reason (see outLapOwed). Kept as it is so every client and
    -- every binding that already reads it starts honoring the race case without
    -- being changed to do it.
    qualiOutLap    = outLapOwed(),
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
    -- Timed races. raceLeft is the clock the header counts down; raceExpired
    -- says it has run out and the field is waiting on the leader; lastLapNum is
    -- the lap everyone still running finishes on once the leader has been past.
    raceMode       = race.raceMode,
    raceTimeLimit  = race.raceTimeLimit,
    raceLeft       = race.raceTimeLimit > 0
      and math.max(race.raceTimeLimit - race.time, 0) or nil,
    raceExpired    = race.raceExpired,
    lastLapNum     = race.lastLapNum,
    -- Approved vehicle/setup list (Module 4).
    garage        = garageInfo.list,
    garageEnforce = garageInfo.enforce,
    -- 'parts' or 'strict'. Which half of a setup the list is matched on, so the
    -- panel can label the switch and the capture button truthfully.
    garageMode    = garageInfo.mode,
    -- Whether clients should hang display names off BeamMP's nametags.
    -- Purely a client-side presentation rule; the server neither renders
    -- nor enforces anything about it, it just holds the switch so every
    -- client agrees.
    nametags      = race.nametags,
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
local function forceSpectate(pid, reason, source, place)
  MP.TriggerClientEvent(pid, 'RM_ForceSpectate', Util.JsonEncode({
    reason = reason or 'You are out of this session',
    source = source or 'race',
    -- Where they finished, for the driver's own "you placed Nth". Sent only on
    -- the finish path and LOCKED HERE, at the crossing: it is the count of
    -- drivers already home, so it cannot be revised by anything that happens to
    -- the field afterwards.
    place  = place,
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
    -- THE LAYOUT LIST IS PRIVILEGE-DEPENDENT NOW, so logging in has to resend it.
    --
    -- A driver is only shown the layouts approved for practice. This client
    -- asked for the list when it joined and got that shorter one; nothing else
    -- ever sends it again, so an admin logged in and went on looking at a panel
    -- saying "no saved layouts" with thirteen of them on disk.
    --
    -- Sent HERE rather than fixed on the client, because the privilege changes
    -- here. A client asking again would be guessing at when it had become
    -- allowed to see more.
    --
    -- Through the GLOBAL handler, not sendLayoutList directly: that local is
    -- declared two and a half thousand lines below this one, so naming it here
    -- compiles to a nil global read and throws the moment somebody logs in.
    -- scope_test caught exactly that.
    RM_onRequestLayouts(pid)
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
  -- AND IT SURVIVES A RESTART NOW. This used to change the password in memory
  -- only, so every restart quietly put it back to the shipped default and the
  -- first anybody knew was a login that should have worked and did not.
  CFG.adminPassword = newPass
  if saveConfigToDisk() then
    print('[RaceManager] Admin password changed and saved to config.json')
  else
    print('[RaceManager] Admin password changed, but config.json could not be '
      .. 'written: it will revert on restart')
  end
  MP.TriggerClientEvent(-1, 'RM_PasswordChanged', Util.JsonEncode({
    changedBy = MP.GetPlayerName(pid) or ('Player ' .. pid),
  }))
  print('[RaceManager] Admin password changed by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------
-- BeamMP ships an FS API, but it is not present in every build (and not in the
-- headless tests), so everything below falls back to a shell command. Those
-- commands are NOT the same on both platforms and plenty of BeamMP servers are
-- hosted on Windows: cmd has no "mkdir -p" (it takes "-p" as another directory
-- to create) and no "ls", so the POSIX spelling silently did nothing there.
local IS_WINDOWS = package.config:sub(1, 1) == '\\'

local function nativePath(path)
  if IS_WINDOWS then return (path:gsub('/', '\\')) end
  return path
end

local function makeDirectory(dir)
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(dir)
  elseif IS_WINDOWS then
    -- cmd's mkdir already creates intermediate directories; it complains when
    -- the directory exists, which is the normal case here, so stderr is muted.
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
-- Written automatically when a race session ends; one .txt per session so
-- league standings / broadcast scripts can pick them up.
local RESULTS_DIR = 'Resources/Server/RaceManager/results'

local function fmtLap(t)
  if not t then return 'no time' end
  local m = math.floor(t / 60)
  return string.format('%d:%06.3f', m, t - m * 60)
end

local function ensureResultsDir()
  makeDirectory(RESULTS_DIR)
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

-- The three things a race decides beyond the finishing order: who set the
-- fastest lap, who led at half distance, and who gained the most places.
--
-- These used to be worked out inside the results writer and thrown away with
-- the string it built. They are pulled out here because there is now a SECOND
-- consumer -- the cup scorer awards bonus points for exactly these three -- and
-- two implementations of "who is the hard charger" is two rules that can drift
-- apart. One function, one answer, and the results file keeps reading it the
-- way it always did.
--
-- Pure: every value is a player id (or nil) plus the numbers needed to describe
-- it, and nothing here writes to a record. `final` is the race classification,
-- taken as an argument so the caller that has already built one does not pay
-- for a second sort.
local function sessionAwards(final)
  final = final or raceClassification()
  local awards = {
    -- Tracked incrementally as laps are scored (see RM_onLap), so this is a
    -- read rather than a scan of the field.
    fastestLapPid = race.bestLapPid,
    fastestLapTime = race.bestLapTime,
  }

  -- Half-distance leader: whoever completed the half-way lap first.
  --
  -- Half of an odd distance is not a lap, so it rounds UP -- a 5-lap race is
  -- decided at lap 3, the same as a 6-lap one. That is the lap on which a driver
  -- has more of the race behind them than in front, which is what "half way"
  -- means when laps are the only unit available.
  --
  -- lapFirsts already records the first driver to complete each lap (it is what
  -- Laps Led is counted from), so this is a lookup rather than a second pass.
  -- A one-lap race has no half way: lap 1 is the flag.
  awards.halfWayLap = math.ceil(race.totalLaps / 2)
  awards.halfWayPid = (race.totalLaps >= 2) and lapFirsts[awards.halfWayLap] or nil

  -- Hard Charger: most places gained from the grid slot to the finish.
  --
  -- Only a classified finisher can have gained places: a driver who did not
  -- finish has no finishing position to have gained them to. A gain of zero or
  -- less is not a charge, so nobody is awarded it rather than it going to
  -- whoever went backwards least. Ties go to the higher finisher, which is `i`
  -- ascending -- a later driver has to beat the gain outright to take it.
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

local function buildResultsText(cupRound)
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
  -- The lap limit is a limit on TIMED laps, and the out lap is not one of them.
  -- Spelled out because a results file is read months later by somebody who was
  -- not there: "3 lap limit" beside a driver who crossed the line four times is
  -- a discrepancy nobody can settle after the fact.
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
  -- Optional regulation columns: only present when that regulation is armed,
  -- so a plain race exports exactly the same table it always did.
  local jokerCol  = race.jokerEnabled and string.format(' %-7s', 'Joker') or ''
  local resetCol  = race.maxResets >= 0 and string.format(' %-6s', 'Resets') or ''
  -- NO "Line" COLUMN. A branch gate is another way through a checkpoint rather
  -- than a route a driver is on, so there is no lane to name -- and a track with
  -- branch gates now exports exactly the table an ordinary race does.
  add(string.format('%-5s %-6s %-22s %-10s %-9s %s%s%s',
    'Pos', 'Start', 'Driver', 'Best Lap', 'Laps Led', 'Finish', jokerCol, resetCol))
  -- Fastest lap, half-way leader and Hard Charger, decided once for this
  -- session (see sessionAwards) rather than worked out again here.
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
      -- A DNF keeps the place it was running in when it stopped, so the file
      -- records what happened rather than only that it happened: "was P2" and
      -- "was P11" are very different afternoons. Finishers are still listed
      -- above every retirement -- a driver who stopped on lap two did not beat
      -- one who took the flag.
      --
      -- It goes with the reason rather than in the Pos column because that
      -- column is padded to a fixed width and every row after a wider one would
      -- shear. The reason text is already the variable-width field on this row.
      pos = 'DNF'
      finish = (rec.outReason or 'DNF')
        .. (rec.heldPos and (' (was P' .. rec.heldPos .. ')') or '')
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
    add(string.format('%-5s %-6s %-22s %-10s %-9d %-10s%s%s%s%s',
      pos, rec.gridPos and ('P' .. rec.gridPos) or '-',
      displayName(rec), fmtLap(rec.raceBest), rec.lapsLed or 0, finish,
      jokerVal, resetVal, aliasNote(rec), tag))
  end
  if #final == 0 then add('(no drivers)') end
  -- The two award lines. Both are omitted rather than guessed at when there is
  -- no answer -- a race stopped before half distance has no half-way leader,
  -- and a race where nobody gained a place has no hard charger.
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
  -- The championship this race just fed, if there is one. Asked for rather than
  -- assembled here: the points, the order and the ledger all belong to the cup
  -- module, and a second copy of its arithmetic living in the results writer is
  -- how two totals for the same driver come to disagree.
  local cupLines = cupResultsLines and cupResultsLines(cupRound) or nil
  for _, l in ipairs(cupLines or {}) do add(l) end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeResults(cupRound)
  ensureResultsDir()
  local path = uniqueResultsPath('results')
  local text = buildResultsText(cupRound)
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
  -- And never on a track with no joker route. Arming it is refused up front
  -- (RM_onSetJokerEnabled) and dropped when a layout without one loads, so this
  -- is the last line rather than the first -- but it is the line that matters,
  -- because everything it guards against happens HERE: a rule with nothing to
  -- complete disqualifies every driver who finishes, and the only place that is
  -- ever explained is a results file written after they have all gone.
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
-- One lifecycle, two sets of rules. Everything below asks the session what it
-- is running rather than branching on the phase name, so a fix to the grid, the
-- hold, the finish or the respawn lands on both sessions at once.

local function isQualiSession()
  return race.sessionKind == 'quali'
end

-- The lap count the CURRENT session runs to, or nil when it has no lap target
-- (an unlimited qualifying session, closed by its clock or by the admin).
local function sessionLapTarget()
  -- A sprint stage is one traversal, whatever the lap field says. Enforced here
  -- rather than by clamping race.totalLaps, so an admin's lap setting survives
  -- switching a circuit layout back in.
  if race.pointToPoint then return 1 end
  if isQualiSession() then
    if race.qualiLapLimit <= 0 then return nil end
    -- Crossings, not timed laps. The allowance is expressed in laps that COUNT,
    -- and the out lap is one every driver has to make and none of them is
    -- scored for, so it is added on top rather than taken out of the allowance:
    -- a 3 lap session is three flying laps, and the fourth crossing is the one
    -- that ends it.
    return race.qualiLapLimit + (outLapOwed() and 1 or 0)
  end
  -- A RACE's first lap counts, and that is the difference between the two.
  --
  -- Qualifying's out lap is a lap given AWAY: it is not timed and it is not one
  -- of the three you were promised, so it is added on top. A race's first lap is
  -- a racing lap -- it is just not eligible for a lap TIME, because a field
  -- launching from a standing grid, or from slots spread round the circuit, would
  -- otherwise hand fastest lap to whoever started nearest the line. Ten laps
  -- means ten crossings; the first of them sets no time.
  --
  -- UNLESS THE RACE IS RUN TO A CLOCK, in which case there is no lap target at
  -- all and totalLaps is inert. A timed race ends one lap after the leader next
  -- takes the line, which is a rule about crossings and elapsed time and cannot
  -- be expressed as a number of laps in advance: nobody knows how many laps ten
  -- minutes is until it has been driven.
  -- ENDURANCE KEEPS ITS LAP TARGET. It is the other half of "whichever comes
  -- first", and dropping it here is how a 50-lap-or-60-minute race quietly
  -- becomes a 60-minute one.
  if race.raceMode == 'timed' then return nil end
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

-- THE OPENING OF AN ADMIN COMMAND THAT CARRIES A PAYLOAD.
--
-- Seventeen handlers began with the same four or five lines: authenticate,
-- optionally refuse while a session is under way, check the payload is a
-- non-empty string, decode it, check the result is a table. About a hundred and
-- twenty lines of guard across the file, and every one of them a chance to
-- write the next handler with one missing.
--
-- The missing guard is the point, not the line count. A new command without
-- requireAuth is an open door; one without sessionUnderWay lets an admin change
-- the rules under cars already at racing speed. Neither fails visibly in
-- testing -- they fail on a race night, to somebody else.
--
-- `idle` is the only thing that varied, so it is the only argument: pass true
-- for a command that must not run mid-session.
--
-- Returns the decoded table, or nil meaning the handler should return. Callers
-- read as `local data = adminPayload(pid, rawData); if not data then return end`
-- which states both halves at the point of use.
local function adminPayload(pid, rawData, idle)
  if not requireAuth(pid) then return nil end
  if idle and sessionUnderWay() then return nil end
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  return data
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
  -- The RESET ghost ends here, and only that one. It is a timed thing that
  -- exists to cover a car materialising in the pack, and a driver who has just
  -- taken the flag is not doing that.
  --
  -- What replaces it is the FINISHED ghost, which this does not touch: that one
  -- is not a per-driver event at all, it is derived from `status` by
  -- finishedRoster() and applied by every client off the state broadcast. Firing
  -- an event here as well would be two sources of truth for one fact.
  clearGhost(rec.id, 'driver finished')
  -- Their place, counted at the crossing. rec.status is already 'finished'
  -- above, so this driver is included and the count IS their position.
  local place = 0
  for _, r in pairs(players) do
    if r.status == 'finished' then place = place + 1 end
  end
  forceSpectate(rec.id, reason, 'race', place)
  return true
end

-- Retire a driver from the session without a finish: THE one way a record
-- becomes a DNF, whatever ended it -- the admin closing the session, a
-- disconnection, or anything added later.
--
-- It exists to make the position snapshot unconditional. Setting `status` by
-- hand in each of those places is how one of them ends up forgetting, and a
-- driver's classified position quietly depending on which way their race
-- happened to end is exactly the bug this prevents.
--
-- `position` is stamped on every state broadcast (three times a second while a
-- session runs), so it is at most a fraction of a second old here. Before the
-- lights there is no running order yet, so the grid slot is the honest answer.
-- BEHIND THE LAST CAR THAT CAN STILL FINISH.
--
-- Not the place they were running in. A driver retiring from P3 of six does not
-- keep third: the five cars still going will all finish ahead of them, so they
-- are sixth. Retire later and fewer cars are left to pass you, so you classify
-- higher, which is how motorsport has always ordered retirements and is what
-- "behind the last running car" means in practice.
--
-- It also stops two drivers scoring the same position, which the held-position
-- rule could do whenever two cars stopped from the same place.
--
-- Finishers count as ahead too: they already have their positions.
local function retireAsDnf(rec, reason)
  if not rec then return false end
  rec.status = 'dnf'
  rec.outReason = rec.outReason or reason
  -- WHERE THEY WERE, kept separately from where they CLASSIFY. The cup can pay
  -- a retirement at the position it held when it stopped, and the results file
  -- says "was P3"; neither of those is the same fact as finishing sixth of six.
  -- One field could not be both, and it used to try.
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
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  -- Before either branch below, and before the respawn either of them runs: the
  -- session is over, so no reset ghost outlives it. The mass respawn that
  -- follows has a ghost of its own (the clients' 'placement' reason), which is
  -- what keeps a field landing through each other safe -- this one has no more
  -- work to do.
  clearAllGhosts('session ended: ' .. tostring(reason))
  if isQualiSession() then
    -- Qualifying drops back to waiting rather than 'finished': the next thing
    -- an admin does is Generate Grid, and the times just set are what orders it.
    race.phase = 'waiting'
    for _, rec in pairs(players) do
      if onTrack(rec) then rec.status = 'waiting' end
    end
    -- Qualifying points are held, not banked: they belong to the round the race
    -- that follows will be. Scored here rather than at the grid because this is
    -- where the times are final. Does nothing at all unless a cup is running.
    if cupOnSessionComplete then cupOnSessionComplete('quali') end
    respawnAll('race')
    broadcastState()
    MP.SendChatMessage(-1, '[RaceManager] Qualifying is over: ' .. reason .. '.')
    print('[RaceManager] Qualifying closed: ' .. reason)
    return
  end

  local excluded = applyJokerRuling()
  race.phase = 'finished'
  -- Score the cup AFTER the joker ruling and not before: that ruling is what
  -- turns a finisher into a disqualification, and a driver scored ahead of it
  -- would bank winner's points for a race they were excluded from. Does nothing
  -- at all unless a cup is running.
  --
  -- The round it banks is carried to the results file below rather than looked
  -- up there: a cup at its round cap scores nothing, and a file that asked the
  -- cup for "the current round" would then print the previous race's points.
  local cupRound = cupOnSessionComplete and cupOnSessionComplete('race') or nil
  -- The session is over: every car taken off the track comes back.
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
  wipe(players)
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil
  race.time = 0.0
  -- The hold goes with the clock it was measured against.
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


-- Admin switches between opt-in entry and "everyone on the server races".
-- A player putting themselves in or out of the field.
--
-- No admin needed: it is their own participation. Allowed mid-session in one
-- direction only -- you can always drop out, but you cannot join a race that is
-- already running.
-- A driver pulling out of a running session.
--
-- Their own race to end, so no admin rights, and the result is a CLASSIFIED
-- retirement rather than a disappearance: they hold a position, they are in the
-- results file, and they score cup points like any other DNF. Somebody who
-- stops is still somebody who took part.
--
-- Treated exactly like taking the flag from there on: the car comes off the
-- track and the driver goes to spectate, which is the path finishers already
-- use and the only one that handles a car being removed cleanly.
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
  -- ALREADY IN THAT STATE, so nothing changes -- but SAY SO ANYWAY. Returning
  -- silently is what strands a panel that has drifted: the client thinks it is
  -- racing, presses Spectate, the server agrees it is already spectating and
  -- says nothing, and the panel goes on showing the wrong answer with no way to
  -- correct itself. A targeted broadcast here makes every press a resync, so a
  -- disagreement can only ever survive until the driver next touches the button.
  if rec.spectating == want then
    broadcastState(pid)
    return
  end
  -- NEITHER DIRECTION MID-SESSION. Sitting out is a decision about whether you
  -- are in the field, and the field is decided when the grid forms. Dropping out
  -- of a race you are already in is RETIRING, which is a different thing with a
  -- different result: a classified retirement rather than never having entered.
  if sessionUnderWay() then
    MP.SendChatMessage(pid, want
      and '[RaceManager] A session is running. Use Retire to pull out of it; you '
        .. 'can sit the next one out once this ends.'
      or  '[RaceManager] A session is running: you can rejoin the field when it ends.')
    return
  end
  rec.spectating = want
  -- STRAIGHT INTO THE REGISTRY. The record is disposable: the online purge drops
  -- and rebuilds it, and ensurePlayer restores the entry decision from here. Set
  -- the record alone and the next purge silently puts the driver back in the
  -- field, which is how sitting out came undone by itself.
  rememberIdentity(rec)
  if want then
    -- Their car stays exactly where it is and becomes a ghost, the same way a
    -- mid-session joiner's does. Nothing is deleted: in BeamMP a delete is a
    -- delete for everyone, and respawning a field is what caused cars to weld.
    rec.bystander = true
    -- HAND THE SLOT BACK. Spectating between the grid forming and the lights is
    -- the one window where a driver holds a start position they are giving up;
    -- leave it assigned and their client stays parked on the grid all race.
    rec.gridPos = nil
    rec.status  = 'waiting'
    assignGridSlot(rec.id, nil)
    MP.SendChatMessage(-1, '[RaceManager] ' .. rec.name .. ' is spectating.')
  else
    rec.bystander = nil
    MP.SendChatMessage(-1, '[RaceManager] ' .. rec.name .. ' rejoined the field.')
  end
  print(string.format('[RaceManager] %s set spectating=%s', rec.name, tostring(want)))
  -- The derby DERIVES its field from this list, so its panel goes stale the
  -- moment somebody sits out and nothing tells it. An admin reading an entrant
  -- count that is one race behind presses Start Derby expecting a different set
  -- of cars than the one that turns up.
  if derbyEntryListChanged then derbyEntryListChanged() end
  -- TWICE, AND BOTH ARE NEEDED.
  --
  -- Everyone gets the entrant count, which just changed. But `youSpectating` is
  -- a targeted-only field, like youAreAdmin: the global payload is one message
  -- for the whole server and cannot say "you" to anybody. Without the second
  -- send the player who just opted out is the only person not told: their count
  -- drops to zero while their panel still reads "you are entered", and the
  -- button still offers to do the thing they have already done.
  broadcastState()
  broadcastState(pid)
end


-- ---------------------------------------------------------------------------
-- Qualifying session rules
-- ---------------------------------------------------------------------------
-- Ghost mode is enforced client-side (only the client owns collisions); the
-- server just holds the switch and ships it with every broadcast.
-- Display names on the BeamMP nametag.
--
-- The server owns the SWITCH and nothing else. It cannot rename anybody: BeamMP
-- has no server-side setter for a player name, and the guest identity comes from
-- their auth rather than from anything this plugin can reach. What the clients do
-- with the switch is add a suffix to the nametag through BeamMP's own
-- setPlayerNickSuffix, which is text and nothing else -- see the note on
-- nametag.apply in the client bridge for why that is the only acceptable way in.
function RM_onSetNametags(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  race.nametags = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Display names on nametags '
    .. (race.nametags and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onSetGhostQuali(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  race.ghostQuali = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Ghost qualifying ' .. (race.ghostQuali and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Session length: a per-driver lap allowance, a wall-clock limit, or neither.
-- 0 means unlimited for both. Locked while qualifying is actually running so a
-- driver can't have the rug pulled mid-lap.
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
  race.finalLapLeft = CFG.finalLapGrace
  broadcastState()
  MP.SendChatMessage(-1, '[RaceManager] TIME EXPIRED: the lap you are on is your '
    .. 'FINAL LAP. Your session ends as you cross the line.')
  print(string.format('[RaceManager] Qualifying time expired: final lap armed for %d driver(s)',
    driversOnTrack()))
end

-- TIMED RACE: the leader has taken the line with the clock already out, so the
-- lap they have just started is the last one.
--
-- `fromLap` is the lap number that ends the race. Everyone still running
-- finishes by completing it - NOT by their next crossing, which is the rule
-- qualifying uses and would be wrong here. A car two seconds behind the leader
-- has not crossed the line yet when this fires; flagging it off at its next
-- crossing would end its race a lap early, while the leader ran a full one.
--
-- The checkered flag (race.finalLap) is a LATER event, set when the first car
-- actually completes `fromLap`. Only from that point is a crossing terminal for
-- everybody, which is how lapped cars are classified: they get the flag as they
-- come past, wherever they had got to.
local function armRaceFinalLap(fromLap, why)
  if race.lastLapNum then return end
  if driversOnTrack() == 0 then
    finishSession(why or 'the time limit expired')
    return
  end
  race.lastLapNum = fromLap
  broadcastState()
  MP.SendChatMessage(-1, '[RaceManager] FINAL LAP: the leader has taken the line. '
    .. 'Everyone still running finishes at the end of lap ' .. fromLap .. '.')
  print(string.format('[RaceManager] Timed race: final lap is lap %d (%s), %d driver(s) out',
    fromLap, why or 'leader crossed after the clock expired', driversOnTrack()))
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
--   quali   -- fastest qualifying Best Lap first, no-time last (join order breaks ties)
--   reverse -- SLOWEST Best Lap first, so the fastest qualifier starts last;
--              no-time drivers still line up at the back (see below)
--   random  -- a random draw, for a race with no qualifying behind it
--   custom  -- slots the admin pinned by hand come first, in slot order; anyone
--              unpinned falls in behind them, still by quali time
local function orderForGrid(ordered)
  if race.gridMode == 'random' then
    return shuffle(ordered)
  end
  -- Reverse grids invert ONE of the two rules below, and which one is the whole
  -- design of the mode.
  --
  -- Inverted: the times. Slowest qualifier on pole, fastest at the back, which
  -- is the format -- the quick drivers have to come through the field.
  --
  -- NOT inverted: where a driver with no time at all goes. They stay at the
  -- back, behind everyone who set one, exactly as they do in a normal grid. A
  -- literal reversal would put them on pole, and then the fastest way to start
  -- first is to sit in the pits and set nothing -- a reverse grid is meant to
  -- reward the slow, not the absent. It also means the fastest qualifier is last
  -- of the drivers who ran, rather than last on the road, which is the honest
  -- reading of "fastest starts last".
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
  -- The hold goes with the clock it was measured against.
  race.endsAt, race.endReason = nil, nil
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil

  -- Purge ghost records first: drivers kept after disconnecting (DNF/finished,
  -- so the previous results file could list them) must not be re-gridded - a
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
      '[RaceManager] Grid not formed: no entrants (%d connected, %d record(s): %s)',
      connected, #skipped,
      #skipped > 0 and table.concat(skipped, ', ') or 'none'))
    -- Everyone races by default, so an empty field means one of exactly two
    -- things now: nobody is here, or everybody here has pressed Spectate.
    MP.SendChatMessage(-1, connected > 0
      and string.format('[RaceManager] Everyone on the server is spectating '
        .. '(%d connected). Press Race in the Race Manager panel to take part.', connected)
      or '[RaceManager] Nobody is on the server to grid.')
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
    rec.dnfPos     = nil
    rec.heldPos    = nil
    -- THE RACE CLOCK GOES BACK TO ZERO HERE, so anything holding a stamp from
    -- the old one has to go with it. holdCorrectedAt is the one that bites: the
    -- grid-hold rate limiter asks `race.time - holdCorrectedAt`, and a stamp
    -- from the last race makes that NEGATIVE, which reads as "corrected a moment
    -- ago" and suppresses corrections for the first minute of the new race --
    -- exactly when the field is standing on the grid and the hold is the only
    -- thing keeping it there. Only ever seen by an admin running races back to
    -- back, because Reset Session drops the records entirely.
    rec.holdCorrectedAt = nil
    rec.holdCorrections = 0
    -- ...and the splits, for the same reason: they are stamps off a clock that
    -- is about to go back to zero, so keeping them would have the new session's
    -- first checkpoint reading as several minutes behind the old one's.
    rec.splits   = nil
    rec.splitLap = nil
    rec.splitCp  = nil
    rec.gap, rec.intv = nil, nil
    -- Counters the record describes as "this session", so they have to mean it.
    rec.pitStops   = 0
    rec.ghosts     = 0
    -- A qualifying grid also clears the times it is about to replace.
    if isQualiSession() then
      rec.qualiBest = nil
      rec.qualiLaps = 0
    end
    -- Everyone stood on the grid owes the out lap, when the session or the track
    -- says one is owed. Set here as well as at GO so the timing screen can say so
    -- while the field is still being held, rather than only once the lights have
    -- gone out.
    rec.outLap = outLapOwed()
    -- Gridded: no longer a bystander. A grid is where entry is decided, so this
    -- is exactly where a mid-session arrival stops being one.
    rec.bystander = nil
    progress.clear(rec)
    -- Put the car on its start position and hold it there until GO. The order
    -- and the field size travel with the slot so the client can stagger its
    -- placement instead of every car being teleported in the same instant.
    assignGridSlot(rec.id, gridPos, gridPos, #ordered)
  end

  race.phase = 'grid'
  -- Every driver about to be gridded gets the track, whether or not they were
  -- here when it was loaded. A grid is the last moment this can be put right
  -- before it matters, and re-sending to a client that already has it is a
  -- no-op: applying a layout is idempotent.
  race.sendLayoutTo(-1)
  -- A new grid is a new session. Any ghost still standing from the last one is
  -- cleared here rather than carried onto the grid, where the cars are about to
  -- be teleported into position under the placement ghost anyway.
  clearAllGhosts('grid formed')
  broadcastState()
  if race.startSlots > 0 and #ordered > race.startSlots then
    MP.SendChatMessage(-1, string.format(
      '[RaceManager] Warning: %d drivers but only %d start positions placed: '
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
-- GENERATE GRID ALWAYS MEANS "FORM THE RACE GRID". It never starts qualifying,
-- and it is never a no-op.
--
-- It used to return here the moment sessionUnderWay() was true, which is every
-- qualifying session -- silently, with no chat line and no log. From the host's
-- seat that is indistinguishable from the button being broken: they are still in
-- qualifying, pressing the control that is supposed to take them to the race,
-- and nothing happens. "Generate Grid forces qualifying" is what that looks like
-- from outside, and the way out (End Session first) is not written anywhere.
--
-- So a running QUALIFYING session is ended and superseded. The times survive --
-- finishSession is the same path End Session uses, and the grid formed
-- immediately after reads them -- so the common race-night order (run quali,
-- press Generate Grid) now just works.
--
-- A running RACE is still refused, and that is a deliberate exception to
-- "no exceptions": superseding a live race would throw away a result twenty
-- drivers are in the middle of earning, on one misclick, with no undo. It is
-- refused OUT LOUD instead -- the silence is the actual bug here, not the
-- refusal.
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
    -- End it the way End Session does, so the times are scored and kept.
    MP.CancelEventTimer('RM_CountdownTick')
    broadcastCountdown(-1)
    finishSession('qualifying closed by ' .. who .. ' to form the race grid')
    print('[RaceManager] Qualifying superseded by Generate Grid (' .. who .. ')')
  end
  formGrid('race', who)
end

-- How the grid gets filled. Locked once the countdown/race starts.
function RM_onSetGridMode(pid, rawData)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then return end
  local mode = decodeString(rawData, 'mode')
  if mode ~= 'quali' and mode ~= 'reverse' and mode ~= 'random' and mode ~= 'custom' then
    return
  end
  race.gridMode = mode
  broadcastState()
  print('[RaceManager] Grid mode set to "' .. mode .. '" by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Custom grid: pin one driver to one slot. Whoever already held that slot is
-- unpinned, so two drivers can never be pinned to the same place. Takes effect
-- on the next Generate Grid; when the grid is already formed it re-forms the
-- order immediately so the admin sees the result.
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

-- A client reported the start positions of the loaded track layout: how many
-- there are (so the server can warn when the field is bigger than the grid) and
-- where they are (so it can police the hold).
--
-- The coordinates are only accepted while nothing is under way. A grid the
-- server is actively judging cars against must not be redefinable by a client
-- mid-countdown -- that would be a way to move everybody else's idea of where
-- the slots are, which is precisely the check being defeated.
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
        -- Whether the grid sits off the line rides along with the same report, so
        -- a track built in the editor and raced without ever being saved as a
        -- named layout still gives its out lap away. A saved layout sets it again
        -- as it loads; this is the unsaved path.
        --
        -- The branch GATES deliberately do not come this way. The server never
        -- tests a crossing, and a branch gate clears the same checkpoint the main
        -- gate does, so there is nothing about one it could act on. Sending a gate
        -- list it would have to validate against a route length it does not hold
        -- would be validation theatre.
        -- ...but ONLY when no layout came through this server.
        --
        -- This report is sent by pushRouteState, which fires constantly and from
        -- EVERY client, not just an admin -- so one player with start positions
        -- sitting in their local editor could flip the whole server's grid rule
        -- and hand a race an out lap nobody asked for, which is exactly what was
        -- happening: the race ran fine, and told everybody about a lap that was
        -- not timed. A loaded layout is authored, saved and shared, and it is
        -- the authority on its own grid.
        if race.layout == nil then
          race.gridOffLine = data.gridOffLine == true
        end
        -- How many joker gates this client has placed, so the joker lap can be
        -- refused on a track that has none even when it was never saved as a
        -- named layout (see RM_onSetJokerEnabled).
        --
        -- SAME GUARD AS gridOffLine ABOVE, and it was missing here. This report
        -- fires constantly from EVERY client, so right after a layout loads a
        -- client that has not applied it yet -- or a spectator with an empty
        -- editor -- reported zero and wiped the count the layout had just set.
        -- The joker toggle stayed locked on a track with joker gates, and
        -- loading the layout a SECOND time fixed it, because by then everyone
        -- was reporting the route they had. Exactly what was described.
        --
        -- A loaded layout is authored, saved and shared. It is the authority on
        -- its own joker route, and no client's editor overrules it.
        local jg = race.layout == nil and tonumber(data.jokerGates) or nil
        if jg then
          race.jokerGates = math.max(math.floor(jg), 0)
          if race.jokerGates == 0 and race.jokerEnabled then
            race.jokerEnabled = false
            MP.SendChatMessage(-1, '[RaceManager] Joker lap switched off: '
              .. 'the Joker Route was cleared.')
            print('[RaceManager] Joker lap auto-disabled: the joker route was cleared')
            -- Broadcast HERE rather than leaving it to the tail of this handler,
            -- which returns early when the slot count has not changed -- and
            -- clearing a joker route usually does not touch the grid at all. The
            -- toggle has to flip on the admin's panel as it happens, not next
            -- time something unrelated moves.
            broadcastState()
          end
        end
      elseif n ~= #race.startPositions then
        -- A count that no longer matches the coordinates we hold, from a report
        -- that carried none -- an older client, or a build predating the
        -- coordinate report. The grid has changed and what we have is stale, so
        -- it is dropped. Policing the hold against a grid whose slots have moved
        -- would drag cars to the wrong places, which is worse than not policing
        -- at all; the client-side guard still holds them.
        race.startPositions = {}
      end
    end
  end

  if n == race.startSlots then return end
  race.startSlots = n
  broadcastState()
end

-- A driver pitted. The stop itself is entirely the client's -- only it can
-- freeze and repair a car -- so this is the record, for the same reason ghosts
-- and resets are recorded: an admin reading the results should be able to see
-- who stopped, when, and how often, without having been watching.
--
-- Nothing here penalises or rewards a stop. A pit stall is a repair, not a
-- regulation.
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

-- Admin toggled the loaded track between a circuit and a point-to-point sprint.
-- Locked once a session is under way, like every other regulation: the shape of
-- the race must not change under the drivers running it.
function RM_onSetPointToPoint(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  race.pointToPoint = data.enabled == true or data.enabled == 1
  broadcastState()
  print('[RaceManager] Track mode: ' .. (race.pointToPoint and 'POINT TO POINT' or 'circuit')
    .. ' (by ' .. (MP.GetPlayerName(pid) or pid) .. ')')
end

-- ---------------------------------------------------------------------------
-- Grid hold enforcement
-- ---------------------------------------------------------------------------
-- The server owns the hold. It cannot APPLY one -- it has no physics -- so the
-- clients freeze their own cars, and this is the half that makes that
-- trustworthy: every held car reports where it is, and a car that is not where
-- it was put gets pulled back and the correction gets logged.
--
-- This exists because the client-side freeze turned out to have four ways of
-- being silently lost (a late teleport echo, a driver reset on the grid, a
-- vehicle reloaded on the grid, and no re-assert of any kind afterwards), and
-- nothing anywhere noticed. A local guard fixes each of those; this makes the
-- guarantee hold even when the local guard does not run at all.
--
-- Where a slot IS, for a driver who has been assigned one. nil when the track's
-- grid was never reported -- an admin who built start positions live and never
-- saved a layout, on a build predating the coordinate report -- in which case
-- the server keeps out of it and the client-side guard is what enforces the
-- hold. Better to police nothing than to police against a grid we do not have.
local function slotPosition(rec)
  if not rec or not rec.gridPos then return nil end
  local list = race.startPositions
  if type(list) ~= 'table' then return nil end
  -- Only judge against a grid that matches the one the field was gridded on. If
  -- the slot count and the coordinate count disagree, what we hold describes a
  -- different track and slot N is not where we think it is.
  if #list ~= race.startSlots then return nil end
  return list[rec.gridPos]
end

-- Is this a moment when cars are meant to be standing still on the grid?
local function holdInForce()
  return race.phase == 'grid' or race.phase == 'countdown'
end

-- A held client reported where its car is. If it is off its slot by more than
-- the tolerance, pull it back.
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

  -- HORIZONTAL distance. The slot's stored height is where a car is DROPPED,
  -- and it then falls onto its suspension -- often most of the tolerance on its
  -- own. Judged in three dimensions, a car standing perfectly still on its slot
  -- reads as having moved, and the correction that follows drops it again, and
  -- it settles again: a loop that pins the car in the air being reset. Creeping
  -- off the line is a move across the ground, so that is what is measured.
  local dx, dy = x - slot.x, y - slot.y
  local drift = math.sqrt(dx * dx + dy * dy)
  if drift <= CFG.holdTolerance then
    rec.holdWarned = nil
    return
  end

  -- Corrections are rate-limited per driver on the server clock as well as on
  -- the client: a car being physically pushed by someone else could otherwise
  -- generate a correction on every report for as long as the shoving lasts.
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

-- Apply a display name to one driver, or clear it when `raw` is blank.
--
-- THE single place a display name changes, and factored out of the event
-- handler for that reason: the cup roster has to be told whenever one does, or
-- a name an admin set would not be the name that survives a restart. Returns
-- `ok, message` -- the caller decides who hears about it.
local function applyAlias(rec, raw)
  raw = tostring(raw or '')
  if raw:gsub('%s', '') == '' then
    if not rec.alias then
      return true, rec.name .. ' has no display name to clear.'
    end
    local was = rec.alias
    rec.alias = nil
    rememberIdentity(rec)
    -- The roster entry is NOT deleted here. Clearing a name says "stop showing
    -- this on the leaderboard", not "throw away the cup points earned under
    -- it"; the binding is dropped and the entry waits to be bound again.
    if rosterUnbind then rosterUnbind(rec.id) end
    return true, 'Display name cleared for ' .. rec.name .. ' (was "' .. was .. '").'
  end

  local clean, why = sanitizeAlias(raw)
  if not clean then return false, 'Name rejected: ' .. why .. '.' end
  if aliasInUse(clean, rec.id) then
    return false, 'Name rejected: "' .. clean .. '" is already in use.'
  end

  rec.alias = clean
  -- Into the registry, not just onto the record: the record is rebuilt by the
  -- next Start Qualifying and the name has to outlive that.
  rememberIdentity(rec)
  -- And into the roster, which outlives the server process. This is also what
  -- reattaches a reconnected driver to the cup points they already have: the
  -- roster matches on the name, so typing it again binds them back to the same
  -- entry rather than starting them a new one.
  if rosterRemember then rosterRemember(rec) end
  return true, 'Display name "' .. clean .. '" set for ' .. rec.name .. '.'
end

function RM_onSetAlias(pid, rawData)
  -- Not "return quietly": a client can believe it is an admin while the server
  -- disagrees (a restart empties authenticatedPlayers while the client bridge
  -- still holds its own flag), and silence there looks exactly like a broken
  -- button. Say so, and the client drops its stale admin state.
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

  -- A blank alias clears it and falls back to the real guest name.
  local ok, msg = applyAlias(rec, decodeString(rawData, 'alias') or '')
  if ok then broadcastState() end
  aliasResult(pid, ok, msg)
end

-- Host sets the race distance. Locked once the countdown/race is under way.

-- A race runs to a LAP COUNT or to a CLOCK, never both, and this is the one
-- handler that sets either. Sending 0 seconds is what puts a race back on laps;
-- the panel's mode toggle does exactly that, so the two can never both be armed.
--
-- Refused while a session is under way (adminPayload's `idle`): changing the
-- distance of a race that is being driven is not a setting, it is a result.
-- How long this race is, in words. One phrasing, so the console line, the
-- results header and anything added later cannot drift apart.
local function raceLengthLabel()
  if race.pointToPoint then return 'point to point, driven once' end
  if race.raceMode == 'timed' then
    return math.floor(race.raceTimeLimit / 60) .. ' min + 1 lap'
  end
  if race.raceMode == 'endurance' then
    return race.totalLaps .. ' laps or ' .. math.floor(race.raceTimeLimit / 60)
      .. ' min + 1 lap, whichever comes first'
  end
  return race.totalLaps .. ' laps'
end

function RM_onSetRaceLimits(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local laps = tonumber(data.laps)
  local secs = tonumber(data.seconds)
  local mode = tostring(data.mode or '')
  if mode == 'laps' or mode == 'timed' or mode == 'endurance' then
    race.raceMode = mode
  elseif secs then
    -- NO MODE ON THE PAYLOAD: a client from before endurance existed, which
    -- said everything by the numbers alone. Read it the way that client meant
    -- it, so an older panel goes on setting the two lengths it knows about
    -- rather than silently turning every timed race back into a lap race.
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
  -- THE INVARIANT, enforced here rather than trusted to the panel. A lap race
  -- with a clock still set is a race that ends when neither the admin nor the
  -- drivers expect it to, and the mode is the only thing that says which the
  -- admin meant.
  if race.raceMode == 'laps' then
    race.raceTimeLimit = 0
  elseif race.raceTimeLimit <= 0 then
    -- Asked for a clock and gave none. Nothing to run to, so it is a lap race
    -- whatever the button said.
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
-- Host sets how many vehicle resets/repairs each driver gets per session.
--   -1 (or any negative value)  unlimited (default)
--    0                          no resets at all - the first one ends your race
--    N                          N resets, the N+1st ends your race
-- Locked once the countdown/race is under way so the rule can't change under a
-- driver who has already spent their allowance.
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

-- Client pressed a reset it was not entitled to. The client BLOCKS the reset -
-- it puts the car straight back where it was - so this is not a penalty and
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
-- Reset ghosting
-- ---------------------------------------------------------------------------
-- A client reset and ghosted itself. The duration it asks for is CLAMPED here,
-- not trusted: the client computes the same number from the same broadcast
-- rules, but it is the client, and a modified one asking for a five-minute ghost
-- would otherwise get one.
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
  -- The audit line, and the reason "reset to phase through the pack" is
  -- answerable from a log rather than from an argument in the chat. Where the
  -- car was comes from the live telemetry the client already reports, so this
  -- costs no extra traffic: running order, lap, and how far it was from its next
  -- checkpoint at the moment it went intangible.
  print(string.format(
    '[RaceManager] %s GHOSTED %.1fs at race time %.1fs: P%s, lap %s, %s to next gate%s (ghost #%d this session)',
    rec.name, requested, race.time,
    tostring(rec.position or '?'), tostring(rec.currentLap or '?'),
    rec.distNext and string.format('%.0fm', rec.distNext) or 'distance unknown',
    repeated and ', TIMER RESTARTED' or '', rec.ghosts))
  broadcastState()
end

-- The owning client reports the space around its car clear and its collision
-- restored. Only that client can know this -- it is the one running the
-- occupancy check -- so the server takes it at its word and relays it.
function RM_onGhostEnd(pid)
  pid = pidKey(pid)
  if not pid then return end
  if clearGhost(pid, 'client reported clear') then broadcastState() end
end

-- The client has been waiting on an occupied space for longer than it thinks is
-- reasonable. A WARNING ONLY: nothing here shortens the ghost or forces it off,
-- because forcing it off is the one thing that welds two cars together. It is
-- logged so an admin watching a driver sit inside another car has something to
-- point at.
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
-- Host arms/disarms the joker requirement. The joker route itself is a second
-- checkpoint set built in the client editor and shipped with the track layout;
-- the server only needs to know whether the rule is in force. Locked during a
-- countdown/race so drivers can't be judged against a rule that appeared
-- mid-race.
function RM_onSetJokerEnabled(pid, rawData)
  local data = adminPayload(pid, rawData, true)
  if not data then return end
  local want = data.enabled == true or data.enabled == 1
  -- A JOKER LAP WITH NO JOKER ROUTE DISQUALIFIES THE ENTIRE FIELD.
  --
  -- The rule is "complete the joker exactly once, or you are reclassified at the
  -- flag" (applyJokerRuling). With no gates placed there is nothing to complete,
  -- so every driver who finishes is disqualified for missing a route that does
  -- not exist -- and nothing says why until the results file is written.
  --
  -- Refused rather than accepted-and-ignored: an admin who armed this meant to
  -- arm something, and silently having it off would be its own surprise.
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
  -- Grid audit (Module 4). REPORTS, and deliberately does nothing else: the
  -- live check has already taken the car off any non-admin who declared an
  -- illegal setup, so anyone still listed here is either an admin (exempt by
  -- design) or a case the live check could not act on. Deleting a car in the
  -- last seconds before GO would do more damage to the race than starting with
  -- one wrong setup in it, and it is the admin's call either way.
  local bad = garageAudit and garageAudit() or {}
  if #bad > 0 then
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
  race.phase = 'countdown'
  countdownValue = CFG.countdownFrom
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
  -- Every session starts green. A caution belongs to the session it was called
  -- in, and carrying one into the next race is the kind of state nobody thinks
  -- to check.
  race.flag = 'green'
  race.time = 0.0
  -- The hold goes with the clock it was measured against.
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
      -- GO: the clock is zero and nobody has reached anything yet.
      rec.splits   = nil
      rec.splitLap = nil
      rec.splitCp  = nil
      rec.gap, rec.intv = nil, nil
      progress.clear(rec)
    end
  end
  -- What this session is about to run under, kept for the results file that is
  -- written long after the rule has moved on (see race.qualiOutLapRun).
  if isQualiSession() then race.qualiOutLapRun = outLapOwed() end
  -- The same record for the race half of the file. A ten lap race that ran
  -- eleven crossings should say which one it gave away, or the lap column and
  -- the setting an admin typed disagree with nothing to explain it.
  if not isQualiSession() then race.raceOutLapRun = outLapOwed() end
  broadcastState()
  -- The out lap is the first thing that happens in a qualifying session, so it
  -- is announced at GO rather than left for drivers to work out from a clock
  -- that never started. Chat, because it reaches a driver who has not opened the
  -- app; the app itself says it again on the driver's own timing readout.
  if outLapOwed() and isQualiSession() then
    MP.SendChatMessage(-1, '[RaceManager] GO! Your first lap is an OUT LAP: it is '
      .. 'not timed and does not count. Timing starts as you cross the line.')
  elseif outLapOwed() then
    MP.SendChatMessage(-1, '[RaceManager] GO! Your first lap COUNTS but is not '
      .. 'timed: a standing start is not a lap time.')
    -- WHY, in the console, because "my race keeps giving a lap away and I do not
    -- know what is asking for it" is otherwise unanswerable from the outside.
    print('[RaceManager] Out lap owed: sessionKind=' .. tostring(race.sessionKind)
      .. ', gridOffLine=' .. tostring(race.gridOffLine))
  end
  local target = sessionLapTarget()
  -- The target is a count of CROSSINGS, so a qualifying session logs the two
  -- halves it is made of rather than a number that matches neither the setting
  -- an admin typed nor the laps that will appear on the board.
  local lapNote
  if isQualiSession() then
    lapNote = (race.qualiLapLimit > 0 and (race.qualiLapLimit .. ' timed lap'
      .. (race.qualiLapLimit == 1 and '' or 's')) or 'unlimited timed laps')
      .. (outLapOwed() and ' + out lap' or '')
  else
    lapNote = (target and (target .. ' laps') or 'unlimited laps')
      .. (outLapOwed() and ' (incl. out lap)' or '')
  end
  print('[RaceManager] GO! (' .. (isQualiSession() and 'qualifying' or 'race') .. ', '
    .. lapNote .. ')'
    .. (race.jokerEnabled and not isQualiSession() and ': JOKER LAP REQUIRED' or '')
    .. (race.maxResets >= 0 and (': resets limited to ' .. race.maxResets) or ''))
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
      retireAsDnf(rec, 'DNF - Session ended')
    end
  end
  finishSession('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onResetLeaderboard(pid)
  if not requireAuth(pid) then return end
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  -- Reset Session is the "start the evening again" button, so nothing stays
  -- ghosted through it. A ghost is ended by the client that owns it reporting
  -- the space around its car is clear, and a client that has been through a
  -- session reset -- or a driver who has quit and come back -- has no such
  -- report left to give. Without this the roster could hold a ghost nobody was
  -- ever going to clear, and every other client would go on seeing that car as
  -- intangible for the rest of the night.
  clearAllGhosts('session reset')
  wipe(players)
  wipe(lapFirsts)
  race.bestLapTime, race.bestLapPid = nil, nil
  race.phase = 'waiting'
  race.sessionKind = 'race'
  race.time = 0.0
  -- The hold goes with the clock it was measured against.
  race.endsAt, race.endReason = nil, nil
  race.qualiTime = 0.0
  race.qualiOutLapRun = false
  race.finalLap     = false
  race.finalLapLeft = 0
  race.raceExpired  = false
  race.raceExpiredAt = nil
  race.lastLapNum   = nil
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
--   dist -- meters to the center of the next checkpoint (metric 3)
--
-- This deliberately does NOT broadcast: with a full grid reporting at 3 Hz that
-- would be dozens of broadcasts a second. The values are just stored, and the
-- race tick loop re-sorts and pushes the running order on its own cadence.
local MAX_CHECKPOINTS = 500      -- sanity clamp on a reported checkpoint count
local MAX_REPORT_DIST = 1e6      -- meters; anything beyond this is nonsense

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

  -- CHECKPOINTS cleared on this lap, not gates crossed: a branch gate is another
  -- way through a checkpoint that already exists rather than an extra one, so
  -- this number means the same thing whichever gates a driver took. That is the
  -- whole reason the running order needs no changes for branching -- and the
  -- reason the clamp below is a checkpoint count too.
  local cp = tonumber(data.cp)
  if cp then
    cp = math.floor(cp)
    -- Clamped to the loaded track's own length when the server knows it, which
    -- is tighter than the flat ceiling and free: a layout that came through
    -- RM_LoadLayout told us exactly how many slots a lap has. The scalar stays
    -- as the fallback for a route placed in the editor that the server never saw.
    local ceiling = race.slotCount > 0 and race.slotCount or MAX_CHECKPOINTS
    if cp < 0 then cp = 0 elseif cp > ceiling then cp = ceiling end
    -- A count that went UP is a crossing, not a routine sample. The client
    -- forces a report on the frame after every crossing (checkGates sets
    -- progressLeft = 0 so a position can change hands promptly), so this is
    -- within a frame of the car actually clearing the gate rather than up to a
    -- throttle window late -- which is what makes the split worth stamping at
    -- all. A count that went DOWN is a stale or reordered packet and is left to
    -- the assignment below, exactly as before.
    if cp > (rec.cpCleared or 0) then progress.record(rec, rec.currentLap, cp) end
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
-- report per lap number wins - one arrival order for everyone) and the finish
-- (the session's lap target reached).
function RM_onLap(pid, rawData)
  if not sessionRunning() then return end
  local rec = ensurePlayer(pid)
  if not rec or not onTrack(rec) then return end
  local quali = isQualiSession()

  -- THE OUT LAP, and every rule about it in one place.
  --
  -- A driver's first crossing ends the lap they spent getting off the grid, in
  -- any session that owes one. QUALIFYING throws it away entirely (no best lap,
  -- no session fastest, nothing against the allowance) and returns here. A RACE
  -- keeps the lap and drops only its TIME, falling through to the scoring below
  -- with lapTime suppressed.
  --
  -- Returning before the terminal check matters most once the clock has expired:
  -- race.finalLap makes the next crossing terminal for everyone still out, and a
  -- driver on their out lap would otherwise be stood down with no time at all,
  -- eliminated by the one lap the session promised not to score. The crossing
  -- still counts as a crossing: lap counter advances, telemetry cleared.
  --
  -- A RACE'S FIRST LAP SETS NO TIME. It is a lap off a STANDING START, and a lap
  -- that begins at a standstill is not the same measurement as a flying one: it
  -- carries the launch, the run to the first corner and whatever the field did
  -- to each other on the way there. Leaving it in the fastest-lap contest scores
  -- a driver against a lap nobody else was driving either.
  --
  -- This used to be gated on rec.outLap, which is only set when the grid sits
  -- AWAY from the start/finish line -- so on an ordinary circuit the standing
  -- lap went on the board like any other.
  --
  -- The crossing still COUNTS. It is one of the laps the race promised: the
  -- counter advances, laps led is credited, telemetry clears. Only the time goes.
  --
  -- NOT ON A ONE-LAP RACE, because there the standing lap is the only lap there
  -- is and dropping its time leaves the results with no times in them at all.
  -- THE LINE IS CHECKPOINT 0 OF THE LAP THAT IS STARTING, and it is stamped
  -- here -- above every early return below, so a qualifying out lap leaves a
  -- split like any other crossing rather than a hole the backfill has to guess
  -- at. On the terminal crossing this is the flag itself: currentLap is left
  -- where it was for a finisher, so the stamp is the one thing that says where
  -- they got to, and it carries exactly the value finishTime does.
  progress.record(rec, (rec.currentLap or 0) + 1, 0)

  local untimedFirstLap = false
  if not quali and (rec.currentLap or 0) <= 1 and (race.totalLaps or 0) > 1 then
    rec.outLap = false
    untimedFirstLap = true
    MP.SendChatMessage(rec.id,
      '[RaceManager] First lap done: it counts, but it set no lap time.')
  end
  if rec.outLap and quali then
    rec.outLap = false
    progress.clear(rec)
    rec.currentLap = rec.currentLap + 1
    broadcastState()
    -- Told to that driver alone. The out lap is a per-driver event twenty
    -- drivers reach at twenty different moments, and announcing each of them to
    -- the whole server would bury the messages that are everybody's business.
    MP.SendChatMessage(rec.id,
      '[RaceManager] Out lap complete: your next lap is TIMED.')
    print(string.format('[RaceManager] %s completed their out lap (not timed)', rec.name))
    return
  end

  local lapTime = decodeNumber(rawData, 'lapTime')
  -- The launch is not a lap time. Dropped here rather than at the client so the
  -- crossing is still reported, still counted and still ends the lap -- the only
  -- thing that changes is that nothing goes on the board for it.
  if untimedFirstLap then lapTime = nil end
  if lapTime and lapTime > 0 then
    if not rec.raceBest or lapTime < rec.raceBest then rec.raceBest = lapTime end
    -- Fastest lap of the SESSION, across everyone. One comparison per scored
    -- lap; nothing walks the field for this.
    if not race.bestLapTime or lapTime < race.bestLapTime then
      race.bestLapTime = lapTime
      race.bestLapPid  = rec.id
      print(string.format('[RaceManager] FASTEST LAP: %s %.3fs', rec.name, lapTime))
    end
    -- Qualifying scores on the best lap; that is the whole difference between
    -- the two sessions once the lifecycle is shared.
    if quali and (not rec.qualiBest or lapTime < rec.qualiBest) then
      rec.qualiBest = lapTime
      print(string.format('[RaceManager] %s quali best: %.3fs (lap %d)',
        rec.name, lapTime, (rec.qualiLaps or 0) + 1))
    end
  end

  local completed = rec.currentLap
  -- DID THIS CROSSING LEAD THE LAP. lapFirsts already answers "who reached this
  -- lap number first", which is precisely what "the leader crossing the line"
  -- means - and it is immune to the case that makes a naive "first crossing
  -- after the clock expired" rule wrong, namely a lapped car coming past. Its
  -- lap number was claimed by the leader a lap ago, so it does not set this.
  local ledThisLap = false
  if quali then
    rec.qualiLaps = (rec.qualiLaps or 0) + 1
  elseif not lapFirsts[completed] then
    lapFirsts[completed] = pid
    rec.lapsLed = rec.lapsLed + 1
    ledThisLap = true
  end
  -- New lap (or the flag): the checkpoint/distance telemetry from the lap just
  -- completed must not linger and rank this driver against the next one.
  progress.clear(rec)

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
  --   * completing the final lap of a timed race. Held separately from
  --     race.finalLap because it is a LAP NUMBER, not "your next crossing":
  --     everyone still running gets that whole lap, however far round they were
  --     when the leader started it.
  local lastLap = (target and completed >= target) or race.finalLap
    or (race.lastLapNum ~= nil and completed >= race.lastLapNum)

  -- The leader's crossing after the clock has run out is what starts the final
  -- lap. Read AFTER lastLap is settled, deliberately: the driver who raises the
  -- flag must run the lap they have just begun, not be retired by it.
  if not lastLap and ledThisLap and race.raceExpired and not race.lastLapNum then
    armRaceFinalLap(completed + 1)
  end

  if lastLap then
    -- FIRST CAR HOME ON THE FINAL LAP OF A TIMED RACE: the checkered flag is
    -- out. From here every crossing is terminal, which is what classifies the
    -- cars behind - including any that are a lap or more down and would
    -- otherwise still be owed a lap number they will never reach.
    if race.lastLapNum and completed >= race.lastLapNum and not race.finalLap then
      race.finalLap     = true
      race.finalLapLeft = CFG.finalLapGrace
      MP.SendChatMessage(-1, '[RaceManager] CHECKERED FLAG: '
        .. displayName(rec) .. ' wins. Everyone still out is classified as they cross.')
    end
    -- ENDURANCE, reaching the DISTANCE rather than the clock. The flag falls on
    -- the first car home and everyone else is classified as they come past,
    -- which is what a race with a time limit on it means by "over".
    --
    -- Deliberately not done for a plain Laps race, where every driver runs the
    -- full distance and a lapped car goes on circulating until it has. That is
    -- long-standing behavior a league's results are built on; changing it is a
    -- decision about how races are scored, not a detail of this mode.
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
    -- A car that is done is taken off the track: it has nothing left to gain and
    -- a parked (or cruising) driver is an obstacle for everyone still running.
    -- Every one of them comes back at the flag (respawnAll in finishSession), so
    -- nobody is left stranded.
    retireDriver(rec, why)
    print(string.format('[RaceManager] %s completed %d lap(s) at %.3fs (led %d)%s',
      rec.name, completed, race.time, rec.lapsLed, race.finalLap and ' [final lap]' or ''))
    if quali and target and completed >= target then
      -- The ALLOWANCE, not the crossing target it was turned into: a driver told
      -- they have used all four laps of a session an admin set to three would be
      -- right to ask which one they were given.
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
    -- ARM THE HOLD rather than closing on the spot. Idempotent, for the same
    -- reason the derby's is: two drivers taking the flag in the same tick must
    -- not push the end further away, or a bunched finish extends the session.
    --
    -- Only the AUTOMATIC ending is held. An admin pressing End Session means
    -- now and gets now, which is why this is here rather than in finishSession.
    --
    -- What the hold buys happens because the phase is still 'racing' underneath
    -- it: finished drivers stay ghosted, the checkered flag stays out, and the
    -- field gets a moment to look at the finish.
    local why = race.finalLap and 'every driver took the flag'
      or (quali and 'every driver used their lap allowance' or 'all drivers finished')
    -- RACES ONLY. A qualifying session ending is not a finish anybody watches:
    -- there is no flag, no placement and nothing ghosted to look at, and holding
    -- it just delays the grid the admin is waiting to generate.
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
  -- ...and the TRACK with it. This is the request a client fires on joining a
  -- server, so it is the moment a late arrival gets the gates everyone else
  -- already has. Without it the layout only ever reached whoever happened to be
  -- connected when the admin pressed Load, and the workaround was waiting for the
  -- whole field to spawn before loading anything.
  race.sendLayoutTo(pid)
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
  makeDirectory(LAYOUTS_DIR)
end

-- ---------------------------------------------------------------------------
-- config.json: the settings file, beside layouts.json
-- ---------------------------------------------------------------------------
-- Read once at boot, written out with the built-in values the first time so
-- there is always a file to edit rather than a format to guess at.
--
-- A KEY THE FILE DOES NOT MENTION KEEPS ITS BUILT-IN VALUE, and an unknown key
-- is ignored. That makes the file safe to trim to the two lines somebody
-- actually cares about, and safe to carry across an upgrade that adds settings.
--
-- Every value is validated against the same limits the live commands use. A
-- hand-typed file is exactly where a lap count of "ten" or a negative countdown
-- comes from, and one bad line must cost that line rather than the boot.
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
  num('totalLaps', 1, CFG.maxTotalLaps)
  num('maxResets', -1, CFG.maxResetLimit)
  str('resetMode', { inplace = true, checkpoint = true })
  bool('nametags')
  num('countdownFrom', 1, 60)
  num('endDelay', 0, 120)
  num('qualiLapLimit', 0, CFG.maxQualiLaps)
  num('qualiTimeLimit', 0, CFG.maxQualiTime)
  num('finalLapGrace', 10, 3600)
  bool('ghostOnReset')
  num('ghostMinSeconds', 0, 120)
  num('ghostMaxSeconds', 0, 300)
  num('holdTolerance', 0.1, 10)
  num('holdCorrectEvery', 0.05, 5)
  -- The ghost window has to be a window. A file with min above max would ghost
  -- nobody, silently, for the whole season.
  if CFG.ghostMinSeconds > CFG.ghostMaxSeconds then
    print('[RaceManager] config.json: ghostMinSeconds is above ghostMaxSeconds; swapping them')
    CFG.ghostMinSeconds, CFG.ghostMaxSeconds = CFG.ghostMaxSeconds, CFG.ghostMinSeconds
  end
  return applied
end

-- Write the current settings out. Called when the file is missing, and again
-- whenever something durable changes (the admin password).
saveConfigToDisk = function ()
  ensureLayoutsDir()
  local f = io.open(CONFIG_FILE, 'w')
  if not f then
    print('[RaceManager] Could not write ' .. CONFIG_FILE)
    return false
  end
  f:write(jsonStringify({
    adminPassword  = CFG.adminPassword,
    totalLaps      = CFG.totalLaps,
    maxResets      = CFG.maxResets,
    resetMode      = CFG.resetMode,
    nametags       = CFG.nametags,
    countdownFrom  = CFG.countdownFrom,
    endDelay       = CFG.endDelay,
    qualiLapLimit  = CFG.qualiLapLimit,
    qualiTimeLimit = CFG.qualiTimeLimit,
    finalLapGrace  = CFG.finalLapGrace,
    ghostOnReset   = CFG.ghostOnReset,
    ghostMinSeconds = CFG.ghostMinSeconds,
    ghostMaxSeconds = CFG.ghostMaxSeconds,
    holdTolerance   = CFG.holdTolerance,
    holdCorrectEvery = CFG.holdCorrectEvery,
  }))
  f:close()
  return true
end

-- The race table is built at load time from CFG's built-in values, which is
-- before config.json has been read -- so the file's values have to be pushed
-- into it afterwards. Anything an admin can also change from the panel starts
-- here and is theirs to move from then on.
local function applyConfigToRace()
  race.totalLaps      = CFG.totalLaps
  race.maxResets      = CFG.maxResets
  race.resetMode      = CFG.resetMode
  race.nametags       = CFG.nametags
  race.endDelay       = CFG.endDelay
  race.qualiLapLimit  = CFG.qualiLapLimit
  race.qualiTimeLimit = CFG.qualiTimeLimit
  adminPassword       = CFG.adminPassword
end

local function loadConfigFromDisk()
  local f = io.open(CONFIG_FILE, 'r')
  if not f then
    -- First run on this server. Write what the plugin ships with, so the admin
    -- has a complete, valid file in front of them instead of a blank page.
    if saveConfigToDisk() then
      print('[RaceManager] Wrote default settings to ' .. CONFIG_FILE)
    end
    return
  end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' then
    -- A broken file is NOT a reason to refuse to start. A league whose server
    -- will not boot because of a stray comma has a worse evening than one
    -- running last week's lap count.
    print('[RaceManager] ' .. CONFIG_FILE .. ' could not be read ('
      .. tostring(data) .. '); using built-in defaults')
    return
  end
  local n = applyConfigTable(data)
  print(string.format('[RaceManager] Settings loaded from config.json (%d value%s): '
    .. '%d laps, resets %s, countdown %d, ghost %.0f-%.0fs',
    n, n == 1 and '' or 's', CFG.totalLaps,
    CFG.maxResets < 0 and 'unlimited' or tostring(CFG.maxResets),
    CFG.countdownFrom, CFG.ghostMinSeconds, CFG.ghostMaxSeconds))
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
sanitizeCheckpoints = function (raw)
  if type(raw) ~= 'table' then return nil end
  -- The symbols a marker may carry. Mirrors marker.KINDS in the client
  -- extension and is kept in step by hand; a symbol missing from here is
  -- dropped rather than stored, so the failure mode is a marker that reverts to
  -- the default rather than a layout that will not load.
  --
  -- INSIDE the function, not beside it. This file is at Lua's 200-local ceiling
  -- too -- the same one the client extension documents -- and one more up there
  -- stops the whole plugin compiling. Rebuilt per call, which costs nothing:
  -- this runs on save and load, not per frame.
  local MARKER_KINDS = {
    right = true, left = true, up = true, down = true,
    uturn = true, splitRight = true, splitLeft = true,
  }
  local out = {}
  for i, cp in ipairs(raw) do
    if type(cp) ~= 'table' then return nil end
    local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
    if not (x and y and z) then return nil end
    out[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
    if tonumber(cp.width)  then out[i].width  = tonumber(cp.width)  end
    if tonumber(cp.height) then out[i].height = tonumber(cp.height) end
    -- DEPTH IS BACK, and it means something new.
    --
    -- The old one was a third box dimension and was dropped when a gate became a
    -- flat rectangle. This one is the other half of the vertical: height is how
    -- far the gate rises above the point it was placed at, depth how far it
    -- drops below. A gate used to be centerd, so making it tall enough to see
    -- buried an equal amount of it under the road.
    --
    -- Carried, not validated against height: they are independent, and a gate
    -- with no depth is a legal gate that simply does not reach below the surface.
    if tonumber(cp.depth) then out[i].depth = tonumber(cp.depth) end
    -- Gates score in either direction; oneWay puts one back for the geometry
    -- where direction is the only thing separating two legs of a track. Carried
    -- only when set, like the size overrides above.
    if cp.oneWay == true then out[i].oneWay = true end
    -- A DIRECTION MARKER'S SYMBOL, carried but never interpreted. The server
    -- has no idea what these mean and does not need one: markers are signage,
    -- they arm nothing and score nothing, and the only thing this side owes
    -- them is storing what an admin placed and handing it back unchanged.
    --
    -- Whitelisted rather than passed through, because this is the one field on
    -- a checkpoint that reaches the client as a LOOKUP KEY. Anything else in it
    -- draws nothing at all, silently, on every client at once.
    if type(cp.kind) == 'string' and MARKER_KINDS[cp.kind] then
      out[i].kind = cp.kind
    end
  end
  if #out == 0 then return nil end
  return out
end

-- Branch gates: a flat list, each carrying the checkpoint it is another way
-- through. Rejects rather than repairs, like every other sanitizer here -- a
-- layout that half-loaded would put drivers on a track that is not the one that
-- was saved.
--
-- `slotCount` is the main route's length, and every slot number is checked
-- against it: a branch gate for a checkpoint that does not exist is a gate no
-- driver can ever be asked for, and clamping it into range would arm it at a
-- different corner of the track instead.
--
-- SEVERAL GATES MAY SHARE A CHECKPOINT and that is the feature, so unlike the
-- version this replaced there is no duplicate-slot rejection. Three ways through
-- one corner is three branch gates on the same slot.
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

-- WHAT THIS PLAYER IS ALLOWED TO SEE.
--
-- An admin gets every layout on the map. Everybody else gets the ones approved
-- for practice, and this is the authoritative half of that rule: hiding rows in
-- the UI is presentation, and a client that stopped hiding them would be asking
-- for a list the server had already sent. The unapproved ones never leave the
-- server for a non-admin at all.
--
-- A broadcast reaches admins and drivers on one wire and cannot be tailored, so
-- it carries what the least privileged recipient may have -- and every admin is
-- then sent the full list addressed to them, which lands second.
local function layoutsVisibleTo(pid, list)
  -- isAuthenticated, NOT requireAuth. This is a visibility question, not a
  -- refused command: requireAuth tells the client its login has lapsed, which
  -- for a driver who never had one would log them out of nothing, repeatedly,
  -- every time a layout list went out.
  if pid and isAuthenticated(pid) then return list end
  local out = {}
  for _, l in ipairs(list) do
    if l.practice == true then out[#out + 1] = l end
  end
  return out
end

local function sendLayoutList(targetPid)
  local all, map = layoutsForCurrentMap()

  -- BROADCAST IS -1, NOT nil. Every call site in this file spells it out, so a
  -- `if targetPid then` here reads as "one player" for the broadcasts too --
  -- which quietly sent every admin the driver-visible list and emptied the
  -- layout panel of whoever had just pressed Save.
  if targetPid and targetPid ~= -1 then
    local list = layoutsVisibleTo(targetPid, all)
    print(string.format('[RaceManager] Sending layout list to %s: %d of %d layout(s), map %s',
      tostring(targetPid), #list, #all, map))
    MP.TriggerClientEvent(targetPid, 'RM_Layouts',
      Util.JsonEncode({ map = map, layouts = list }))
    return
  end

  -- A BROADCAST IS TWO DIFFERENT LISTS, so it cannot be one broadcast.
  --
  -- The safe list goes to everyone, and every admin then gets the full one
  -- addressed to them, which lands second and replaces it. The alternative --
  -- broadcasting the safe list and leaving admins to re-request -- empties the
  -- layout panel of the admin who just pressed Save, until they happen to
  -- refresh it. Their own layout vanishing is not a subtle failure.
  local safe = layoutsVisibleTo(nil, all)
  print(string.format('[RaceManager] Sending layout list to all: %d of %d layout(s), map %s',
    #safe, #all, map))
  MP.TriggerClientEvent(-1, 'RM_Layouts', Util.JsonEncode({ map = map, layouts = safe }))
  if #safe == #all then return end            -- nothing withheld: nothing to top up
  for pid in pairs(authenticatedPlayers) do
    MP.TriggerClientEvent(pid, 'RM_Layouts', Util.JsonEncode({ map = map, layouts = all }))
  end
end

function RM_onRequestLayouts(pid)
  sendLayoutList(pid)
end

-- Approve (or un-approve) a layout for practice.
--
-- Allowed WHILE A SESSION IS UNDER WAY, unlike the rest of the layout commands.
-- It changes nothing about the running race: no gates move, no rule changes,
-- nothing is sent to anybody in the session. It only decides what a driver may
-- pull up on their own afterwards, and refusing it for twenty minutes because a
-- race is on would be a rule with no reason behind it.
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

-- Send the loaded track to one client, or to everyone with -1.
--
-- Called wherever somebody might not have it: when a player joins, when they ask
-- for state, and when a grid forms. Sending it again to a client that already has
-- it is harmless -- applying a layout is idempotent, and it is the same payload
-- they applied the first time.
function race.sendLayoutTo(target)
  if type(race.layout) ~= 'table' then return false end
  MP.TriggerClientEvent(target or -1, 'RM_ApplyLayout', Util.JsonEncode(race.layout))
  return true
end

-- Strict track-state purge. Drops the in-memory layout cache (the next access
-- re-reads layouts.json from disk, so nothing stale survives in a global) and
-- orders every client to delete its checkpoint arrays and 3D gate visuals.
-- Broadcast on server boot and immediately before a new layout is applied, so
-- ghost checkpoints from an earlier session can never leak into a new one.
local function clearTrackState(reason)
  layouts = nil
  race.layout = nil
  -- The track's RULES go with the track. A purge that left gridOffLine standing
  -- carried the old layout's out lap onto whatever was loaded next -- including
  -- onto no track at all, where nothing could explain where it came from.
  race.gridOffLine = false
  race.slotCount   = 0
  race.branches    = {}
  race.jokerGates  = 0
  MP.TriggerClientEvent(-1, 'RM_ClearTrack', Util.JsonEncode({ reason = reason or 'clear' }))
  -- The panel has to hear about all of that. Same gap the layout LOAD had: the
  -- fields above are session state the UI displays, RM_Tick does not run while
  -- no session is going, and RM_ClearTrack only carries the gates. Clearing a
  -- track left the joker toggle and the grid count reading the old layout's.
  broadcastState()
  print('[RaceManager] Track state cleared: ' .. (reason or 'clear'))
end

-- Client/UI asked for an explicit full clear (also refreshes everyone's list).
function RM_onClearTrackState(pid)
  if not requireAuth(pid) then return end
  clearTrackState('requested by ' .. (MP.GetPlayerName(pid) or pid))
  sendLayoutList(-1)
end

-- NOTHING LOADED: no race track, no derby arena, one press.
--
-- The two live in separate modules with separate state, separate broadcasts and
-- separate clears, so "put the server back to nothing" was two commands on two
-- different tabs and the second was easy to forget. What that leaves behind is
-- not obvious either: an arena with no race track still draws its walls, and a
-- track with no arena still arms its gates.
--
-- Forwarded through the derby's OWN handlers rather than reaching into its
-- state. Two reasons, and the second is the one that would have bitten:
--
-- The derby is a module with its own state and its own broadcast, and going
-- through its public entry points is the boundary the file was split along.
-- It also has to be done this way round: `derby` is a local declared some six
-- hundred lines BELOW this, so naming it here would compile fine and resolve to
-- a nil global the first time an admin pressed the button. The RM_* handlers
-- are globals and resolve at call time, which is exactly what is needed.
--
-- Refused mid-session for the same reason a load is: this pulls the track out
-- from under whoever is driving on it.
function RM_onClearEverything(pid)
  if not requireAuth(pid) then return end
  if sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] Not while a session is running: end it first.')
    return
  end
  local who = MP.GetPlayerName(pid) or pid
  clearTrackState('cleared by ' .. who)
  sendLayoutList(-1)
  -- "No arena loaded" is an empty boundary and an empty start grid. The rules
  -- (wall height, the out-of-bounds and demolished timers, the reset allowance)
  -- are settings rather than an arena and are deliberately left alone: an admin
  -- clearing the map is not asking for their timers to be reset too.
  --
  -- Each of these refuses on its own while a derby is running, so a running
  -- derby is safe without a check here.
  RM_onDerbyClearBoundary(pid)
  RM_onDerbyClearStarts(pid)
  local msg = '[RaceManager] Everything cleared by ' .. who
    .. ': no race track and no derby arena are loaded.'
  MP.SendChatMessage(-1, msg)
  print(msg)
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
  -- What is already stored under this name, if anything. Held before the new
  -- entry is built, because the whole point of the check below is to compare the
  -- two -- see the silent-drop guard after it.
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
    -- Optional rallycross joker route (Module 2): a second, independent gate
    -- set stored with the layout. Absent on plain circuits.
    joker       = sanitizeCheckpoints(data.joker),
    -- Optional starting grid: where the cars line up for this track.
    startPositions = starts,
    -- Optional pit lane: stalls a driver may pull into for a repair. Kept out
    -- of the checkpoint list on purpose -- they are an area, not a gate to be
    -- passed in order, and lap validation must never see them.
    pits         = sanitizeCheckpoints(data.pits),
    -- Signage travels with the track it points around: a stage without its
    -- markers is a stage nobody can follow.
    markers      = sanitizeCheckpoints(data.markers),
    -- Sprint stage or circuit. A property of the track, not of the session.
    pointToPoint = data.pointToPoint == true,
    -- APPROVED FOR PRACTICE: may a non-admin load this on their own, with no
    -- session running, to drive it and be timed locally?
    --
    -- Opt-in, and it defaults to FALSE for every layout including ones saved
    -- before this existed. A track an admin is midway through building, or one
    -- kept back for an event, should not become public the moment the server
    -- learns the word "practice". Turning it on is one click; turning it back
    -- off after somebody has already been driving it is not.
    --
    -- Carried through a re-save so editing a layout never silently revokes its
    -- approval, which would look like the toggle not working.
    practice     = (data.practice == true) or (existing ~= nil and existing.practice == true),
    -- Optional branching routes: the other ways round this track. Validated
    -- against the main route's length, so a slot number can never point past the
    -- end of the lap it is overriding.
    branches     = sanitizeBranches(data.branches, #checkpoints),
    -- Does the grid sit somewhere other than the start/finish line? Decides
    -- whether a race gives its first lap away (see outLapOwed) -- and a head-on
    -- layout, whose two directions cannot share a row of slots, always does.
    gridOffLine  = data.gridOffLine == true,
  }
  -- A branch array that was sent but did not survive validation is a rejected
  -- save, not a track quietly saved without its other way round: half the field
  -- would be driving at a gate that is not there.
  if data.branches ~= nil and not entry.branches then
    print('[RaceManager] Save rejected: branch gates malformed '
      .. '(bad or out-of-range checkpoint number, or bad coordinates)')
    return
  end
  -- ---------------------------------------------------------------------
  -- The silent-drop guard. A save writes whatever the sending client is holding,
  -- so any client path that empties one collection and leaves the route alone
  -- turns the next same-name save into unannounced data loss. Reported live as a
  -- track that came back with no joker route, no pit stall and no grid.
  --
  -- A save that would empty a section the stored layout HAS is refused and
  -- reported back; the UI asks and re-sends confirmDrop. Only whole sections
  -- count: deleting one of six start positions is ordinary editing.
  if existing and data.confirmDrop ~= true then
    local function had(t) return type(t) == 'table' and #t or 0 end
    local lost = {}
    local function checkSection(key, before, after)
      if before > 0 and after == 0 then lost[key] = before end
    end
    checkSection('joker',          had(existing.joker),          entry.joker and #entry.joker or 0)
    checkSection('pits',           had(existing.pits),           entry.pits and #entry.pits or 0)
    checkSection('startPositions', had(existing.startPositions), starts and #starts or 0)
    checkSection('branches',       had(existing.branches),       entry.branches and #entry.branches or 0)
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

-- Show the field a flag. Green or yellow, admin only, and only while something
-- is actually running: a caution with nobody on track is noise.
--
-- Announced in chat as well as broadcast, because the panel is not where a
-- driver's eyes are when a caution is called.
function RM_onSetFlag(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  local want = tostring(data.flag or '')
  if want ~= 'green' and want ~= 'yellow' and want ~= 'red' then return end
  if not sessionUnderWay() then
    MP.SendChatMessage(pid, '[RaceManager] No session is running, so there is nothing to flag.')
    return
  end
  if want == race.flag then return end
  race.flag = want
  local who = MP.GetPlayerName(pid) or pid
  if want == 'red' then
    MP.SendChatMessage(-1, '[RaceManager] RED FLAG: stop where you are and wait. '
      .. 'The session is still running; it goes yellow, then green. By ' .. who .. '.')
  elseif want == 'yellow' then
    MP.SendChatMessage(-1, '[RaceManager] YELLOW FLAG: caution called, race back to the line. By ' .. who .. '.')
  else
    MP.SendChatMessage(-1, '[RaceManager] GREEN FLAG: racing. By ' .. who .. '.')
  end
  print('[RaceManager] Flag set to ' .. want .. ' by ' .. tostring(who))
  broadcastState()
end

-- Delete a saved layout by name, under the current map only. Refused mid-session
-- like loading is. A deleted layout that is currently loaded is forgotten too:
-- race.layout pointing at a removed entry would keep serving joining players a
-- track nobody could load again.
function RM_onDeleteLayout(pid, rawData)
  if not requireAuth(pid) then return end
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
      if race.layout == l then
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

-- Load a saved layout, in one of TWO senses, and the difference is the whole
-- point of this handler.
--
--   forEditing = true   Private. The layout goes to the ONE admin who asked and
--                       nowhere else, and no server state moves. This is an
--                       admin opening a track to work on it.
--
--   forEditing = false  Public. The layout becomes the track the server is
--                       racing: broadcast to everybody, race.* updated, chat
--                       told. This is what Load Layout has always done.
--
-- Both were the second one, which is why two admins could not build anything at
-- the same time. Opening a track to edit it moved the whole server onto it and
-- overwrote whatever the other admin had in progress. The client-side buffer
-- guard stops the damage; this is what stops the collision happening at all.
--
-- Locked once a countdown/race is under way in both senses - nobody swaps the
-- track mid-race, and nobody edits during one either.
function RM_onLoadLayout(pid, rawData)
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end
  -- A PRACTICE LOAD IS THE ONE FORM OF THIS ANY PLAYER MAY SEND, so the admin
  -- guard runs after the payload is known rather than before it. Everything the
  -- practice branch is then allowed to do is targeted at the sender and touches
  -- no race state; its own rules (approved layout, no session running) are
  -- enforced inside it.
  if data.forPractice ~= true then
    if not requireAuth(pid) then return end
    if sessionUnderWay() then return end
  end

  local list, map = layoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- PRIVATE LOAD: this admin's editor, and nothing else.
      --
      -- Targeted rather than broadcast, and it returns before a single race.*
      -- field is touched. That is what makes two admins on one map independent:
      -- neither the gates nor the grid nor the joker count leave this client, so
      -- there is nothing for the other admin's session to notice.
      --
      -- The purge is targeted for the same reason, and it has to be sent: the
      -- client drops its old gates on RM_ClearTrack, and an apply without one
      -- would leave the previous track's checkpoints standing underneath.
      -- PRACTICE LOAD: any player, no session running, approved layouts only.
      --
      -- The same targeted shape as the editor load below and for the same
      -- reason -- it returns before a single race.* field is touched, so a
      -- driver pulling up a track to practice on cannot disturb anybody else's
      -- session, or each other's.
      --
      -- The approval is re-checked HERE rather than trusted from the list that
      -- was sent. A client can ask for any name it likes; the list is what it
      -- was shown, not what it may have.
      if data.forPractice == true then
        if l.practice ~= true then
          MP.SendChatMessage(pid, string.format(
            '[RaceManager] "%s" is not open for practice.', l.name))
          return
        end
        -- WAITING, NOT merely "not under way".
        --
        -- sessionUnderWay() is false during the GRID phase on purpose: an admin
        -- may still set laps and rules while the field is lined up. Practice is
        -- a different question. Loading a practice track clears this client's
        -- gates and applies another set -- doing that to a driver standing on
        -- the grid for a real session would take the race away from them a
        -- moment before the lights.
        --
        -- 'finished' is excluded for the smaller version of the same reason: the
        -- results are up and the field is still on track.
        if race.phase ~= 'waiting' then
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
        MP.SendChatMessage(pid, string.format(
          '[RaceManager] Practising on "%s". Your laps are timed for you only, '
          .. 'and count for nothing.', l.name))
        print(string.format('[RaceManager] Practice layout "%s" loaded by %s',
          l.name, MP.GetPlayerName(pid) or pid))
        return
      end
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

      -- Purge first: every client must drop its existing gates before the new
      -- set arrives, so no checkpoint from a previous layout can survive.
      clearTrackState('loading layout "' .. l.name .. '"')
      -- The grid this track was saved with is now the grid the session uses.
      race.startSlots = (type(l.startPositions) == 'table') and #l.startPositions or 0
      -- The grid the hold is judged against comes from the layout being loaded,
      -- not from whichever client happens to report next.
      race.startPositions = (type(l.startPositions) == 'table') and l.startPositions or {}
      race.pointToPoint = l.pointToPoint == true
      -- The lanes and the grid's relationship to the line arrive with the track,
      -- so an admin who built a head-on oval gets one back rather than a circuit
      -- that has forgotten half of what makes it work.
      race.branches    = (type(l.branches) == 'table') and l.branches or {}
      race.gridOffLine = l.gridOffLine == true
      race.slotCount   = #l.checkpoints
      -- The joker arms against the track that is loaded, not the one that was.
      -- Loading a circuit with no joker route while the joker lap is switched on
      -- would otherwise disqualify the whole field at the flag.
      race.jokerGates  = (type(l.joker) == 'table') and #l.joker or 0
      if race.jokerGates == 0 and race.jokerEnabled then
        race.jokerEnabled = false
        MP.SendChatMessage(-1, '[RaceManager] Joker lap switched off: "' .. l.name
          .. '" has no Joker Route.')
        print('[RaceManager] Joker lap auto-disabled: the loaded track has no joker gates')
      end
      race.layout = l
      print(string.format('[RaceManager] Broadcasting RM_ApplyLayout: "%s", %d checkpoint(s), %d start position(s), width %s',
        l.name, #l.checkpoints, race.startSlots, tostring(l.width)))
      MP.TriggerClientEvent(-1, 'RM_ApplyLayout', Util.JsonEncode(l))
      -- TELL EVERYONE, and not just about the gates.
      --
      -- Loading a layout sets the joker gate count, the grid size, whether the
      -- grid is off the line, the branch gates and point-to-point. All of that is
      -- session state the panel displays, and none of it went anywhere: this
      -- handler broadcast the LAYOUT and nothing else.
      --
      -- Nothing covered for it either, because RM_Tick returns immediately when
      -- no session is running, so there is no periodic broadcast while waiting
      -- for one. The joker toggle stayed locked on a track that has joker gates
      -- until some unrelated thing pushed state, and loading the layout a second
      -- time was the reliable way to find one. That is the "click Load Layout
      -- twice" report, and it survived a first fix aimed at the wrong half.
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
-- An admin drives the car they want to allow, presses "Whitelist Current
-- Vehicle", and the client captures that vehicle's exact configuration (model
-- + full part config + tuning variables) as a signature string. Repeat to build
-- a Garage List of allowed cars.
--
-- Enforcement has two layers, because the server has no physics/vehicle
-- introspection of its own:
--   1. BeamMP's onVehicleSpawn / onVehicleEdited hooks: the raw payload carries
--      the jbeam model name ("jbm"), so a car whose *model* is not on the list
--      is canceled outright before it ever exists for other players.
--   2. RM_VehicleConfig: the client reports the exact signature of every
--      vehicle it spawns or re-tunes. A signature that is not on the list gets
--      the vehicle removed and an error pushed to that player's UI.
-- NOBODY IS EXEMPT, admins included. Building the list is done with Enforcing
-- switched off, and an empty list never enforces anything, so the two cases
-- that used to need the exemption are both covered without one.
local GARAGE_FILE        = LAYOUTS_DIR .. '/garage.json'
local MAX_GARAGE_ENTRIES = 60
local MAX_SIG_LENGTH     = 4000

local garage = {
  enforce = false,   -- master switch for the whole rule
  -- WHICH HALF OF THE SIGNATURE IS MATCHED, and the reason this is a setting
  -- rather than a constant: a league does not run one rule all season.
  --
  --   'parts'  model + parts. Tuning and paint are the driver's business.
  --            The default, and the common case: a spec series locks what the
  --            car IS and lets people set it up.
  --   'strict' model + parts + tuning. Nothing moves at all.
  --
  -- Several allowed builds of the same car (a choice of engine, say) is not a
  -- third mode - it is several entries under 'parts', one per build.
  mode    = 'parts',
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
  -- Anything that is not the word 'strict' is 'parts'. A file written before
  -- modes existed has no key at all and lands on the default, which is the
  -- looser of the two: an upgrade must not silently start rejecting the tuning
  -- changes a league was already allowing.
  garage.mode = (data.mode == 'strict') and 'strict' or 'parts'
  garage.list = {}
  local derived = 0
  for _, e in ipairs(type(data.list) == 'table' and data.list or {}) do
    if type(e) == 'table' and type(e.sig) == 'string' and e.sig ~= '' then
      -- Entries captured before the split carry only the full signature. The
      -- parts half is a literal PREFIX of it ('model=X|parts=Y|vars=Z'), so it
      -- is recovered here rather than demanded back off the admin as a
      -- re-capture. Greedy '.*' so a part name that somehow contained the
      -- marker still splits at the LAST one, which is the real boundary.
      local partsSig = e.partsSig
      if type(partsSig) ~= 'string' or partsSig == '' then
        partsSig = e.sig:match('^(.*)|vars=')
        if partsSig then derived = derived + 1 end
      end
      garage.list[#garage.list + 1] = {
        model    = tostring(e.model or '?'),
        label    = tostring(e.label or e.model or 'Vehicle'),
        sig      = e.sig,
        -- nil only if the signature had no vars marker at all, which no
        -- release has ever written. Such an entry still matches in strict
        -- mode; garageAllows skips it in parts mode rather than guessing.
        partsSig = partsSig,
        game     = (type(e.game) == 'string' and e.game ~= '') and e.game or nil,
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

-- The compact view every state broadcast carries, held until the garage
-- actually changes. nil means "rebuild on the next broadcast".
--
-- Rebuilding it per broadcast meant a table per approved car, three times a
-- second, for the lifetime of the server -- describing a list an admin touches
-- perhaps twice in a session.
local garageView = nil

local function saveGarageToDisk()
  -- The one place the cached view is dropped, and deliberately the only one.
  -- Persisting the garage and invalidating the view are the same event: every
  -- path that alters the list or the enforcement flag has to come through here
  -- or the change would not survive a restart either, so there is no second rule
  -- to remember somewhere else.
  garageView = nil
  -- And the same argument for the drivers' verdicts. A ruling reached against
  -- the OLD list is not evidence about the new one, and clients only re-declare
  -- when their own car changes -- so an admin who adds the entry that legalises
  -- somebody would have left them marked as an offender until they next
  -- happened to touch their setup. Re-judged from the signatures already on
  -- record instead of cleared, so the panel is correct immediately rather than
  -- blank until everyone reports again.
  if garageRejudge then garageRejudge() end
  ensureLayoutsDir()
  local f, ferr = io.open(GARAGE_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({
    -- version 2 added `mode` and the per-entry `partsSig`. A version 1 file
    -- still loads: loadGarageFromDisk defaults the mode and derives the missing
    -- signature half, so downgrading the plugin is the only thing this breaks.
    version = 2, enforce = getGarage().enforce, mode = getGarage().mode,
    list = getGarage().list,
  }))
  f:close()
  return true
end

-- Assigned to the forward-declared local near broadcastState so every state
-- broadcast can carry the current Garage List without the racing code knowing
-- how it is stored.
--
-- The table handed back is SHARED between broadcasts, which is the whole point
-- of caching it. Nothing may write to it: broadcastState only reads two fields
-- off it, and the encoder does not touch its argument.
garageSnapshot = function ()
  if garageView then return garageView end
  -- getGarage() first: the lazy load from disk has to have happened before the
  -- view is built off it, and that is what makes the initial load need no
  -- invalidation of its own.
  local g = getGarage()
  -- Signatures can be long; the UI only ever displays model/label, so ship a
  -- compact view (the signature stays server-side).
  local list = {}
  for i, e in ipairs(g.list) do
    list[i] = { model = e.model, label = e.label }
  end
  garageView = { list = list, enforce = g.enforce, mode = g.mode }
  return garageView
end

-- Enforcement only bites when it is switched on AND at least one car has been
-- captured - an empty whitelist would otherwise lock every player out.
local function garageEnforcing()
  local g = getGarage()
  return g.enforce and #g.list > 0
end

-- EXACT-duplicate test, and deliberately always on the full signature whatever
-- the mode is. A capture that differs only in tuning adds nothing under 'parts'
-- but is a distinct, meaningful entry under 'strict' - and an admin building a
-- list on a Tuesday for a strict race on a Friday would be blocked from adding
-- it if this followed the mode. Only a byte-identical capture is a duplicate.
local function garageHasSig(sig)
  for _, e in ipairs(getGarage().list) do
    if e.sig == sig then return true end
  end
  return false
end

-- Does this setup match anything on the list, under the mode currently in
-- force? The ONE place the mode is interpreted, so 'parts' cannot mean one
-- thing to the live check and another to the grid audit.
--
-- An entry with no partsSig is skipped rather than guessed at in parts mode.
-- That only happens to a signature with no vars marker in it, which no release
-- has ever written; loadGarageFromDisk derives the rest.
local function garageAllows(partsSig, fullSig)
  local strict = getGarage().mode == 'strict'
  for _, e in ipairs(getGarage().list) do
    if strict then
      if fullSig and fullSig ~= '' and e.sig == fullSig then return true end
    else
      if partsSig and partsSig ~= '' and e.partsSig == partsSig then return true end
    end
  end
  return false
end

-- Re-rule every driver against the list as it stands now. Called from
-- saveGarageToDisk, so a capture, a removal, Clear Garage, the enforcement
-- switch and the mode switch all get this for free.
--
-- Reads only what RM_onVehicleConfig already recorded. A driver who has never
-- declared has no signature and stays at nil, which is "no answer yet" and not
-- "offender" -- the distinction the panel and the audit both depend on.
garageRejudge = function ()
  local enforcing = garageEnforcing()
  for _, rec in pairs(players) do
    if not enforcing or not rec.carSig then
      rec.carOk = nil
    else
      rec.carOk = garageAllows(rec.carPartsSig, rec.carSig)
    end
  end
end

-- Who is about to start a race in a car the Garage List does not cover.
--
-- Assigned to the forward declaration near broadcastState so the countdown can
-- reach it. Reads the verdicts RM_onVehicleConfig and garageRejudge already
-- recorded rather than re-deriving anything: the server has no vehicle
-- introspection of its own, so the last declaration IS the evidence.
--
-- Admins appear in this list. They are never removed from their car, which is
-- precisely why they have to be visible here - an admin exempt from the check
-- AND absent from the audit is an unapproved car nobody can see.
--
-- A driver with no verdict at all (carOk nil) is not an offender. That is
-- "hasn't declared yet", not "illegal", and treating the two the same would
-- flag every driver for the first seconds after enforcement is switched on.
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

-- The bare jbeam name, however the two sides happen to spell it.
--
-- The list stores whatever veh:getJBeamFilename() returned and the spawn packet
-- carries "jbm", and there is no promise anywhere that those agree on case, on
-- a leading path, or on the .jbeam extension. A mismatch there refuses a car
-- that is plainly on the list, with a message blaming the model, so the
-- comparison is made on the part both forms always share.
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

-- A signature mismatch on a car whose MODEL is approved is the shape a stale
-- Garage List takes after a BeamNG update that renamed vehicle parts: the
-- driver is in an allowed car, but the stored signature was built from part
-- names the game no longer uses. When the entry was captured on a different
-- build than the driver is running, say so - the admin has to re-capture, and
-- nothing on the server can work that out for them. Returns nil when the
-- versions match, are unknown, or the model was never approved in the first
-- place, so an ordinary "you tuned a car that isn't allowed" rejection keeps
-- its plain wording.
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

-- Tell a driver their car is not allowed, and (unless `advisory`) have it
-- deleted.
--
-- THE DELETION HAPPENS ON THE CLIENT, which is not where it looks like it
-- should. MP.RemoveVehicle wants BeamMP's own per-player vehicle id - the one
-- handed to onVehicleSpawn below - and the id arriving on RM_VehicleConfig is
-- the client's veh:getID(), a BeamNG game object id from an unrelated numbering
-- space. So the call matched nothing and failed silently inside its pcall, and
-- every refused setup produced a message and no consequence. The client knows
-- which car is its own without any id, so it is sent the order instead.
--
-- The MP.RemoveVehicle call is KEPT, guarded on a vid that came from a source
-- that actually uses BeamMP ids (the spawn hook passes one; the config report
-- does not, and passes nil). Where the id is right it removes the car server-
-- side too, which is a second belt on the one path that has one.
--
-- `advisory` told a driver without taking the car away. NOTHING PASSES IT NOW:
-- admins are refused on the same terms as everyone else, which is a deliberate
-- reversal of how this shipped. Building the list is done with Enforcing OFF -
-- an admin who needs an unapproved car in order to capture it turns the switch
-- off first, and an empty list never enforces anything, so the first capture of
-- a session needs no special case either.
--
-- The branch is KEPT rather than deleted. Which way this rule should point is a
-- league decision that has already changed once, and putting it back is passing
-- `true` from the two call sites again rather than rebuilding the path under
-- time pressure on a race night.
local function rejectVehicle(pid, vid, why, advisory)
  if MP.RemoveVehicle and vid and not advisory then
    pcall(MP.RemoveVehicle, pid, vid)
  end
  MP.TriggerClientEvent(pid, 'RM_VehicleRejected', Util.JsonEncode({
    message = advisory
      and 'Vehicle/Setup not on the Garage List (admin: not removed).'
      or  'Vehicle/Setup not allowed in this session.',
    detail  = why or '',
    -- The client deletes its own car on this flag and on nothing else.
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
    -- ANSWERED TO THE ADMIN, not just the console. This used to print and
    -- return, so the button did nothing visible and the car was believed to be
    -- on a list it had never reached - which then reads as "the Garage List
    -- refuses a car I whitelisted", the hardest kind of bug to see.
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
  -- Clients since the parts/tuning split send both halves. One that does not is
  -- an older build, and its full signature still carries the parts half as a
  -- prefix, so it is recovered here on exactly the rule loadGarageFromDisk uses.
  local partsSig = data.partsSig and tostring(data.partsSig) or ''
  if partsSig == '' or #partsSig > MAX_SIG_LENGTH then
    partsSig = sig:match('^(.*)|vars=')
  end
  local entry = {
    model    = tostring(data.model or '?'),
    label    = tostring(data.label or data.model or 'Vehicle'),
    sig      = sig,
    partsSig = partsSig,
    game     = (type(data.game) == 'string' and data.game ~= '') and data.game or nil,
  }
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
  local data = adminPayload(pid, rawData)
  if not data then return end
  getGarage().enforce = data.enabled == true or data.enabled == 1
  saveGarageToDisk()
  broadcastState()
  print('[RaceManager] Garage enforcement '
    .. (garage.enforce and ('ENABLED (' .. garage.mode .. ')') or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Switch between locking the parts only and locking parts plus tuning.
--
-- The two modes disagree about who is legal, so every driver's verdict is
-- re-judged against the new one. That happens inside saveGarageToDisk, which is
-- where every other change to the list already goes.
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

-- Client reported the configuration of a vehicle it just spawned or re-tuned.
-- Which half of it has to match is the enforcement mode's business, not this
-- function's: it asks garageAllows and does as it is told.
--
-- WHAT IS RECORDED HAPPENS WHETHER OR NOT ENFORCEMENT IS ON, and that is the
-- point of recording it. An admin who builds the list and then flips Enforcing
-- can audit the grid immediately, instead of waiting up to two seconds per
-- client for everyone to re-declare a setup the server was already told about.
--
-- ADMINS ARE REFUSED TOO, on the same terms as everybody else. They still
-- appear in the grid audit; there is simply no longer a class of driver the
-- rule does not reach. See rejectVehicle for how to put the exemption back.
function RM_onVehicleConfig(pid, rawData)
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local sig = data.sig and tostring(data.sig) or ''
  if #sig > MAX_SIG_LENGTH then return end
  local partsSig = data.partsSig and tostring(data.partsSig) or ''
  -- Older client, one signature only. Its parts half is the prefix, same rule
  -- as everywhere else this recovery happens.
  if partsSig == '' and sig ~= '' then partsSig = sig:match('^(.*)|vars=') or '' end
  local model = data.model and tostring(data.model) or ''

  -- A SIGNATURE WITH NO PARTS IN IT IS NOT AN ANSWER, and must never be ruled
  -- on. A client that reports one frame too early (BeamNG has not finished
  -- loading the vehicle's parts yet) sends 'model=X|parts=', which matches no
  -- entry on any list - so the server refuses the very car it was just given,
  -- and the client deletes it. That is the bug that made the Garage List reject
  -- the car it had been built from. The client guards it too; the server
  -- refuses to judge it because an old or patched client cannot be relied on to.
  --
  -- Returned WITHOUT touching rec.carOk. "Ask again in a moment" has to leave
  -- the standing verdict alone: overwriting it with nil would blank the panel
  -- every time anybody respawned.
  if partsSig == '' or partsSig:match('|parts=$') then return end

  local rec = ensurePlayer(pid)
  if rec then
    rec.carSig      = sig
    rec.carPartsSig = partsSig
    rec.carLabel    = data.label and tostring(data.label) or model
    rec.carGame     = data.game and tostring(data.game) or nil
  end

  if not garageEnforcing() then
    -- Nothing to be non-compliant with. Clearing rather than leaving the last
    -- verdict standing: a stale red mark on a driver the server is no longer
    -- policing is worse than no mark at all.
    if rec then rec.carOk = nil end
    return
  end

  local allowed = garageAllows(partsSig, sig)
  if rec then rec.carOk = allowed end
  if allowed then return end

  -- WHAT ACTUALLY DIFFERED, in the server console. A refused driver is told the
  -- rule they broke, which is all a driver can act on; an admin staring at a car
  -- that ought to be on the list needs the two signatures side by side, and
  -- there is nowhere else to get them. Truncated because a full part config is
  -- long and the head of it is where a difference shows.
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
    rejectVehicle(pid, nil, 'the Garage List entry for "' .. stale.label
      .. '" was captured on BeamNG ' .. stale.game .. ' and you are on '
      .. tostring(data.game) .. ': a game update can rename vehicle parts, so an '
      .. 'admin needs to re-capture the Garage List')
    return
  end
  -- Naming the mode in the refusal is what makes it actionable. "Not on the
  -- list" tells a driver nothing about whether the fix is undoing a part swap
  -- or undoing a tune, and those are different evenings.
  rejectVehicle(pid, nil, getGarage().mode == 'strict'
    and 'this exact setup is not on the Garage List (Strict: parts AND tuning are locked)'
    or  'these parts are not on the Garage List (Parts: tuning and paint are free, '
        .. 'parts are locked)')
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
-- DEMO DERBY: its own module now
-- ===========================================================================
-- Twelve hundred lines of arena rules used to sit here. They accounted for 47
-- of this chunk's 200 local slots -- measured by deleting the region and
-- compiling, not by counting declarations -- and taking them out moves this
-- file from NINE free slots to fifty-six.
--
-- Everything the derby needs is handed over ONCE below. Every entry is a stable
-- table or a plain function, so there are no getters: `players` and the rest
-- are cleared in place rather than replaced, which is what makes a reference
-- captured at startup still correct after a session reset.
--
-- The twenty-seven RM_Derby* handlers it defines stay global and are reached by
-- name, so MP.RegisterEvent below needs no change at all.
local derbyMod = require('derby')

derbyMod.init({
  LAYOUTS_DIR = LAYOUTS_DIR, MAX_LAYOUT_NAME = MAX_LAYOUT_NAME,
  RM_PROTOCOL = RM_PROTOCOL,
  aliasNote = aliasNote, decodeString = decodeString, displayName = displayName,
  ensureLayoutsDir = ensureLayoutsDir, ensureResultsDir = ensureResultsDir,
  forceSpectate = forceSpectate, getCurrentMap = getCurrentMap,
  isEntrant = isEntrant, jsonParse = jsonParse, jsonStringify = jsonStringify,
  onlinePlayers = onlinePlayers, releaseSpectators = releaseSpectators,
  requireAuth = requireAuth, respawnField = respawnField,
  uniqueResultsPath = uniqueResultsPath,
  players = players, race = race, sanitizeCheckpoints = sanitizeCheckpoints,
})

-- The host installs these into its own state; the module does not reach over
-- and write them. Both fill forward declarations made much earlier -- the
-- inert `return false` default on race.derbyUnderWay stays exactly where it
-- was, and still applies if this module ever fails to load.
race.derbyUnderWay    = derbyMod.underWay
derbyEntryListChanged = derbyMod.entryListChanged


-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================

-- ===========================================================================
-- DRIVER ROSTER (persistent display names)
-- ===========================================================================
-- Display names used to last exactly as long as a connection did. That was not
-- a choice so much as a consequence: everyone on this server is a guest, BeamMP
-- recycles session ids, and a guest name is regenerated on every join, so there
-- was nothing stable to bind a lasting name to (see the identity registry near
-- the top of this file, which is the in-memory half of the same problem).
--
-- A cup changes what that costs. Points have to follow a driver across races
-- and across a restart, and a name that evaporates takes the points with it.
-- So the anchor becomes the thing that IS stable: an admin's decision, written
-- down. A roster entry is a name an admin gave somebody, kept on disk with the
-- guest name they were using at the time.
--
-- Two ways a driver gets reattached to their entry:
--
--   * automatically, when the guest name still matches -- the same evidence
--     identityFor uses, so a recycled session id can no more inherit a name
--     here than it can there;
--   * by an admin typing the name in again. That is the ordinary case after a
--     reconnect, and it needs no new control: the existing Set box already
--     goes through applyAlias, which lands here. Matching an existing entry by
--     name is what binds the driver back to the points already under it.
--
-- Nothing in this section touches race state. It is read by the cup module and
-- written by applyAlias, and that is the whole of its contact with the rest of
-- the file.
--
-- Everything from here to the end of the CUP module lives inside one installer
-- function, called immediately below it. That is not decoration: Lua allows 200
-- locals per function and this chunk was already near the ceiling, so a module
-- written at file level would not compile. A function body gets its own budget,
-- and the only names that escape are the ones forward-declared far above --
-- which makes the isolation these two sections claim structural rather than
-- merely promised.
local function installRosterAndCup()

-- Assigned by the CUP section below. When an admin binds a connection to a real
-- driver, any provisional entry that connection had been scoring into has to
-- hand its rounds over -- otherwise naming somebody halfway through an evening
-- strands everything they scored before you got to them.
local cupAbsorbEntry

local ROSTER_FILE = LAYOUTS_DIR .. '/roster.json'
local MAX_ROSTER_ENTRIES = 200

-- Declared ahead of rosterRemember, which uses it: naming a driver who has been
-- scoring under a placeholder is one of the two ways a merge happens.
local rosterAbsorb

local roster       = nil   -- lazy-loaded array of { id, name, guest, provisional }
local rosterNextId = 1     -- persisted, so an id is never reused after a restart
-- [pid] = entry id. Runtime only and deliberately not persisted: a binding is a
-- claim about a LIVE connection, and a stale one restored from disk would hand
-- a name to whoever happened to inherit that session id.
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
        -- Reloaded, not dropped. A placeholder that comes back as a real driver
        -- is one rosterAbsorb will refuse to merge, so the points it is holding
        -- for somebody are stranded on it the moment an admin identifies them --
        -- and the panel stops marking it, so nothing says why.
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

-- Case-insensitively, because an admin retyping a name after a reconnect should
-- not have to reproduce the capitalisation to get the points back.
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

-- A driver was given a display name. Three cases, and the order matters:
--
--   1. the name is already in the roster -- bind to THAT entry. This is the
--      reconnect, and binding rather than renaming is what returns a driver to
--      the points they have already scored.
--   2. this connection is bound to an entry under a different name -- rename
--      it. This is an admin naming somebody who was auto-entered under their
--      guest name, and the points move with them because the entry is the same.
--   3. neither -- a new driver, so a new entry.
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
      -- Naming a driver who has already been scoring under a provisional entry
      -- is the admin saying "this is who that was". Their points move with them.
      rosterAbsorb(bound, named)
    end
    -- Matching is case-insensitive but the spelling just typed is the one that
    -- sticks, so the entry and the leaderboard can never end up showing the
    -- same driver under two different capitalisations -- which would also mean
    -- the next restart handed back a name the admin had not typed.
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
  -- An admin has put a name to this entry, so it is no longer a guess.
  entry.provisional = nil
  -- Recorded for the ADMIN's benefit, never matched on: it is what the panel
  -- shows beside a driver so a human can tell who is who. See rosterEnsure for
  -- why a guest name is not evidence of identity.
  entry.guest = rec.name
  rosterBound[rec.id] = entry.id
  saveRosterToDisk()
  return entry
end

-- Move everything a provisional entry accumulated onto the entry it turned out
-- to belong to, then retire it. Points follow the driver; the placeholder goes.
--
-- Only ever applied to a PROVISIONAL entry. Two entries an admin has named are
-- two drivers, and quietly merging them because a connection moved between them
-- would destroy exactly the record this roster exists to keep.
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

-- Bind a connected driver to a roster entry outright. THE admin control for
-- "this player is that driver", and the answer to a reconnect: BeamMP issues a
-- new random guest name every join, so nothing but a person can make this call.
--
-- Refuses rather than guesses. Handing an entry to the wrong connection hands
-- over a season of points with it, so every way that could happen is a refusal
-- with a reason attached.
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

-- Delete an entry. Used for placeholders left behind by drivers who never came
-- back, and for pruning a roster that has filled up. The cup removes its own
-- side separately -- this owns names, not points.
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

-- The roster as the admin panel sees it: who exists, who is connected right now
-- and under which guest name, and which entries are still guesses.
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

-- The entry a driver should be scored against, creating one if they have no
-- display name at all.
--
-- Auto-creating is deliberate. The alternative is dropping the points of any
-- driver an admin forgot to name, silently, and discovering it at the end of a
-- cup -- far worse than a roster line reading "Guest_4471", which an admin can
-- rename later with the points following it (case 2 in rosterRemember).
--
-- It does NOT set an alias: the leaderboard and the results file go on showing
-- the guest name exactly as they do today.
local function rosterEnsure(rec)
  if not rec then return nil end
  local entry = rosterEntryFor(rec)
  if entry then return entry end
  local list = getRoster()

  -- Only the DISPLAY NAME may find an existing entry, because a display name is
  -- something an admin typed. A driver who disconnects mid-race has their live
  -- binding dropped -- it is a claim about a connection, and that connection is
  -- gone -- but their record survives to be classified, so at the moment the cup
  -- scores them they are named and unbound. Matching the name they raced under
  -- puts them back on their own entry.
  --
  -- The GUEST name is never matched against anything. BeamMP issues a fresh
  -- random one on every join, so it identifies nobody: it would miss a returning
  -- driver almost every time, and on the occasion two people were ever issued
  -- the same one it would quietly merge two strangers' seasons.
  entry = rec.alias and rosterByName(rec.alias) or nil
  if entry and rosterClaimedBy(entry.id, rec.id) then entry = nil end

  if not entry then
    -- Nobody this driver can safely be identified as, so they get an entry of
    -- their own. PROVISIONAL: it is a place to keep points that would otherwise
    -- be dropped on the floor, not a claim about who this is. An admin can bind
    -- the driver to their real entry later and the points follow (see
    -- rosterBindTo), which is why losing them here would be the worse failure.
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
-- End of DRIVER ROSTER module
-- ===========================================================================

-- ===========================================================================
-- CUP / SERIES POINTS (isolated module)
-- ===========================================================================
-- A cup is a championship run across several races: points accumulate per
-- driver and only an admin ending the cup clears them.
--
-- This module is a CONSUMER of race results and nothing else. It is entered
-- from exactly one place -- cupOnSessionComplete, called at the end of
-- finishSession -- and it reads the classification the results file is built
-- from rather than recomputing anything. That is what keeps scoring separate
-- from the logic that decides a race, and it is why a bad scoring rule can
-- never affect who won.
--
-- What it does NOT do, deliberately:
--
--   * touch `race`, `players` or `lapFirsts`. It reads them; it writes only its
--     own tables and the roster.
--   * run anything on a tick. Everything here happens once per session end or
--     once per admin action, so a race with a cup running costs exactly what a
--     race without one costs, plus one boolean test.
--   * survive on session state. Cup points live in this module's own table and
--     on disk, so Start Qualifying, Generate Grid, a countdown, Reset Session
--     and a server restart all pass straight through them. Only RM_CupReset
--     clears a cup.

local CUP_FILE = LAYOUTS_DIR .. '/cup.json'
local MAX_CUP_POSITIONS = 60     -- how deep a points table may go
local MAX_CUP_POINTS    = 9999   -- per position, and per bonus
local MAX_CUP_NAME      = 40
local MAX_CUP_ROUNDS    = 200

-- Pre-configured scoring systems, so an admin does not have to type 24 numbers
-- to run a normal championship. Selecting one FILLS the table rather than
-- locking it: the point of a preset is somewhere to start.
--
-- A position past the end of an array scores nothing, which is why the shorter
-- tables simply stop rather than carrying a tail of zeroes.
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
  -- Podium only. Three deep and nothing behind it, which is a whole different
  -- kind of championship: there is no points to be had for turning up and
  -- circulating, so a driver either races the front three or scores nothing.
  --
  -- The table stops at three rather than carrying twenty-one zeroes, because
  -- cupPointsFor returns 0 for any position past the end. "3,2,1" and the same
  -- followed by zeroes are the same scoring system, and this is the short form.
  { key = 'collision-course', label = 'Collision Course',
    race = { 3, 2, 1 } },
}

-- Bonus achievements, as DATA. Each entry names a configurable pot of points,
-- says which DISCIPLINE it belongs to, and says which driver wins it given the
-- awards that session produced.
--
-- `kind` is what keeps a mixed cup honest: a race bonus is not offered to a
-- derby and a derby bonus is not offered to a race, so "fastest lap" can never
-- be quietly paid out on a session that has no laps. The scorer only ever walks
-- the entries matching the session it is scoring.
--
-- Adding another one later -- pole position, most laps led, a clean race -- is
-- one row here plus nothing else. This module never names a bonus outside this
-- table, and the UI builds a control per row, so no new code is written per
-- bonus at either end.
local CUP_BONUSES = {
  { key = 'fastestLap',  kind = 'race',  label = 'Fastest Lap',
    award = function (ctx) return ctx.awards.fastestLapPid end },
  { key = 'halfwayLed',  kind = 'race',  label = 'Halfway Led',
    award = function (ctx) return ctx.awards.halfWayPid end },
  { key = 'hardCharger', kind = 'race',  label = 'Hard Charger',
    award = function (ctx) return ctx.awards.hardChargerPid end },
  -- Derby. Deliberately NOT the same thing as finishing first: a derby can end
  -- with no survivors at all (everybody demolished), and the driver who lasted
  -- longest then tops the classification without having won it. This pays only
  -- when somebody actually survived, which is what "last man standing" means.
  { key = 'derbyWin',    kind = 'derby', label = 'Last Man Standing',
    award = function (ctx) return ctx.winnerPid end },
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

-- BUILT-INS ONLY, and it has to stay that way: the cup table below is seeded by
-- calling this, so this runs before `cup` exists and cannot look inside it.
-- Saved systems are found by cupAnyPresetByKey, further down.
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
    -- Derbies score on a table of their OWN, because a cup may be all races,
    -- all derbies, or a mixture, and the two are not the same event: a derby
    -- field is usually a different size and lasting eight minutes in a banger
    -- is not worth what winning a ten-lap race is worth. It defaults to the
    -- same preset so an all-derby cup works the moment it is started, and an
    -- admin who wants derbies to count for less (or nothing) edits or empties
    -- it without touching the race table.
    derbyPreset = '30p-aggressive',
    derby  = cupCopyTable(cupPresetByKey('30p-aggressive').race),
    -- Empty means qualifying scores nothing, which is the default: a cup that
    -- has not been told to pay for qualifying does not pay for it.
    quali  = {},
    bonus  = cupDefaultBonus(),
    -- The usual league qualification on a fastest-lap bonus: set the fastest
    -- lap and then park it, and you have not really earned anything.
    fastestLapRequiresFinish = true,
    -- What a DNF is worth. A retirement is not always a nil score -- plenty of
    -- series pay a driver for the place they were running when they stopped,
    -- because being taken out of second place is not the same as never turning
    -- up -- and which of these a league wants is a league decision, not
    -- something this plugin should assume:
    --
    --   'none'       a DNF scores nothing. The default, and what every cup
    --                scored before this was configurable.
    --   'classified' a DNF scores for its place in the final classification,
    --                which is below every driver who finished.
    --   'held'       a DNF scores for the place it was RUNNING in when it
    --                stopped. This is the one that can pay two drivers for the
    --                same position -- a retirement from second and a finish in
    --                second both score second -- and that is exactly what a
    --                series choosing it is asking for.
    dnfScoring = 'none',
  },
  -- An ARRAY, not a map keyed by id: the persistence codec only emits string
  -- keys for a table, so an integer-keyed map would serialise to {} and every
  -- point in the cup would vanish on the next restart.
  entries = {},       -- { { entryId, name, rounds = {}, adjustments = {} } }
  -- Qualifying is scored when it ends, but it belongs to the round the race
  -- that follows will be -- so it is held here until that race banks it.
  pendingQuali = {},  -- { { entryId, pos, pts } }
  -- SCORING SYSTEMS AN ADMIN HAS SAVED, alongside the built-in presets.
  --
  -- Kept here rather than in a file of their own because a saved system is not
  -- a championship: End Cup clears the standings and deliberately leaves
  -- cup.scoring alone, so anything filed beside it outlives the cup it was
  -- written during. A league that spends an evening agreeing a points table
  -- should not lose it by ending the season.
  --
  -- Same shape as a built-in preset ({ key, label, race }), so the picker, the
  -- lookup and the load path all take one without knowing which kind it is.
  savedPresets = {},
}
local cupLoaded = false
-- Assigned further down, once the standings it has to serialise exist. Declared
-- here because saving and publishing are the same event (see saveCupToDisk).
local broadcastCupState

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
-- Kept beside layouts.json and NOT under the results directory: Clear Results
-- Cache deletes every .txt it finds there, and a cup that could be destroyed by
-- routine housekeeping is not persistent in any sense that matters.
local function cupSanitizeTable(raw, cap)
  local out = {}
  for i, v in ipairs(type(raw) == 'table' and raw or {}) do
    if i > (cap or MAX_CUP_POSITIONS) then break end
    local n = math.floor(tonumber(v) or 0)
    if n < 0 then n = 0 elseif n > MAX_CUP_POINTS then n = MAX_CUP_POINTS end
    out[i] = n
  end
  -- Trailing zeroes carry no information (past the end scores nothing anyway)
  -- and would otherwise grow the file a little on every save.
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

  -- Saved scoring systems. Sanitised the same way a live table is, so a
  -- hand-edited file cannot put a string or a negative into a points table, and
  -- an entry missing its name or its numbers is dropped rather than loaded as a
  -- blank row in the picker.
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

  -- Only replaced when the file actually carries a scoring block. A cup.json
  -- written by something else, or truncated, must not silently leave the cup
  -- with an empty points table -- that reads as "a race was run and nobody
  -- scored", which is a great deal harder to notice than a parse error.
  if type(data.scoring) == 'table' then
    local s = data.scoring
    cup.scoring.preset = type(s.preset) == 'string' and s.preset or 'custom'
    cup.scoring.race   = cupSanitizeTable(s.race)
    cup.scoring.quali  = cupSanitizeTable(s.quali)
    -- A cup saved before derbies could be scored carries no derby table. Fall
    -- back to the race table rather than to nothing: a file written by an
    -- earlier build describes a cup whose derbies were never scored at all, and
    -- silently loading "derbies are worth zero" would be a scoring change
    -- nobody asked for the next time one was run.
    if s.derby ~= nil then
      cup.scoring.derby = cupSanitizeTable(s.derby)
      cup.scoring.derbyPreset = type(s.derbyPreset) == 'string' and s.derbyPreset or 'custom'
    else
      cup.scoring.derby = cupCopyTable(cup.scoring.race)
      cup.scoring.derbyPreset = cup.scoring.preset
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

-- Persisting the cup and publishing it are ONE event, deliberately: every path
-- that changes a cup has to come through here or the change would not survive a
-- restart either, so there is no second rule to remember about telling the
-- clients. Same reasoning the garage uses for invalidating its cached view.
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
-- Totals are DERIVED, never stored. A cup entry keeps the per-round breakdown
-- and the list of manual adjustments, and the total is the sum of both every
-- time it is asked for -- a few dozen integer additions over a field of
-- drivers. Keeping a running total instead would make the breakdown and the
-- number disagree the first time anything was corrected, and the breakdown is
-- the whole point: an admin has to be able to see where a total came from.
-- Race and derby are totalled SEPARATELY and then combined, rather than being
-- summed into one number and split for display afterwards. A mixed cup has two
-- championships inside it and an admin has to be able to read either on its
-- own, so the per-discipline figures are the primary ones and the grand total
-- is derived from them.
--
-- A round records which kind it was; rounds written before derbies could be
-- scored carry no kind and are races, which is what they were.
local function cupEntryTotals(e)
  local t = {
    race  = { rounds = 0, wins = 0, points = 0, quali = 0, bonus = 0, total = 0 },
    derby = { rounds = 0, wins = 0, points = 0, bonus = 0, total = 0 },
    adjust = 0, rounds = #e.rounds, total = 0,
  }
  for _, r in ipairs(e.rounds) do
    local derbyRound = r.kind == 'derby'
    local side = derbyRound and t.derby or t.race
    side.rounds = side.rounds + 1
    side.points = side.points + (tonumber(r.racePts) or 0)
    -- What counts as a win differs by discipline, and deliberately so. A race
    -- is won by finishing first. A derby is won by being the last one running --
    -- which is NOT the same as topping the classification, because a derby an
    -- admin ends early is topped by somebody who was merely still going. That
    -- driver has not won anything, and a wins column that said otherwise would
    -- disagree with the last-man-standing bonus sitting next to it.
    if derbyRound then
      if r.status == 'winner' then side.wins = side.wins + 1 end
    elseif tonumber(r.racePos) == 1 then
      side.wins = side.wins + 1
    end
    for _, b in ipairs(CUP_BONUSES) do
      side.bonus = side.bonus + (tonumber(r.bonus and r.bonus[b.key]) or 0)
    end
    if r.kind ~= 'derby' then
      t.race.quali = t.race.quali + (tonumber(r.qualiPts) or 0)
    end
  end
  t.race.total  = t.race.points + t.race.quali + t.race.bonus
  t.derby.total = t.derby.points + t.derby.bonus
  for _, a in ipairs(e.adjustments) do
    t.adjust = t.adjust + (tonumber(a.delta) or 0)
  end
  -- Manual adjustments sit outside both disciplines. They are a correction to a
  -- driver's standing in the CUP, not to one of its halves, and pretending to
  -- know which half a penalty belonged to would be inventing information.
  t.total = t.race.total + t.derby.total + t.adjust
  return t
end

-- Cup standings, best first. Ties break on wins, then on the earlier entry --
-- deterministic either way, so the same cup always renders in the same order.
--
-- Each row carries THREE positions: the combined one, and one for each
-- discipline. A mixed cup contains a race championship and a derby
-- championship as well as an overall one, and all three ranking rules stay
-- here rather than being re-derived by whatever is displaying them.
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
      -- Combined.
      wins      = t.race.wins + t.derby.wins,
      bonusPts  = t.race.bonus + t.derby.bonus,
      adjustPts = t.adjust,
      total     = t.total,
      -- The ledger itself, so an admin can see what each adjustment was for
      -- and remove the wrong one rather than guessing from a net figure.
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
  -- Combined last, so the array is left in the order the summary shows.
  rank('total', 'wins', 'pos')
  return list
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------
-- The cup has a channel of its own (RM_CupUpdate), pushed only when something
-- changes, and it is deliberately NOT folded into the main state broadcast.
-- That one goes out three times a second to every client for the whole of a
-- race; hanging a standings table off it would be the one genuinely expensive
-- thing this feature could do. A cup changes a handful of times an evening.
--
-- The preset and bonus lists ride along so the panel renders itself from what
-- the server actually supports, rather than from a copy of the list kept in the
-- UI that has to be edited in step. Adding a bonus later is then a row in
-- CUP_BONUSES and nothing else.
-- Built-ins, then whatever the admin has saved. Everything that LOADS a preset
-- goes through this rather than cupPresetByKey, which cannot see saved ones.
local function cupAnyPresetByKey(key)
  local builtin = cupPresetByKey(key)
  if builtin then return builtin end
  for _, p in ipairs(cup.savedPresets or {}) do
    if p.key == key then return p end
  end
  return nil
end

-- The picker's list: built-ins first, saved systems after, each flagged so the
-- panel can offer Delete on the ones an admin made and not on the ones it
-- ships with.
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

-- The bonus registry as the panel sees it: key, label, the discipline it
-- belongs to, and what it is currently worth. The `kind` is what lets the panel
-- group race bonuses under the race table and derby bonuses under the derby
-- one, without knowing what any individual bonus means.
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
    cupName      = cup.name,
    round        = cup.round,
    preset       = cup.scoring.preset,
    racePoints   = cup.scoring.race,
    derbyPreset  = cup.scoring.derbyPreset,
    derbyPoints  = cup.scoring.derby,
    qualiPoints  = cup.scoring.quali,
    bonuses      = cupBonusList(),
    presets      = cupPresetList(),
    fastestLapRequiresFinish = cup.scoring.fastestLapRequiresFinish,
    dnfScoring   = cup.scoring.dnfScoring,
    -- How many drivers have qualifying points waiting to be banked by the next
    -- race. The admin needs to see that a quali "counted" before the race runs.
    pendingQuali = #cup.pendingQuali,
    standings    = cupStandings(),
    -- The roster, and who is connected right now. The admin panel pairs the two
    -- up: a driver on the server has to be told which roster entry they are,
    -- because nothing on the wire can work that out for itself.
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

-- The cup entry for a driver, created on first sight. Its identity comes from
-- the roster, which is what makes points survive a reconnect: bind the same
-- driver back to the same roster entry and they land on the same cup entry.
local function cupEntryFor(rec)
  local rosterEntry = rosterEnsure(rec)
  if not rosterEntry then return nil end
  local e = cupFindEntry(rosterEntry.id)
  if e then
    -- The roster is the authority on the name, so a rename shows up in the
    -- standings without the cup having to be told separately.
    e.name = rosterEntry.name
    return e
  end
  e = { entryId = rosterEntry.id, name = rosterEntry.name, rounds = {}, adjustments = {} }
  cup.entries[#cup.entries + 1] = e
  return e
end

local function cupPointsFor(tableRef, pos)
  if not pos or pos < 1 then return 0 end
  return tonumber(tableRef[pos]) or 0
end

-- The qualifying ORDER, by best lap.
--
-- Deliberately not qualiClassification(): that one sorts by grid slot first,
-- which is right for the results file (by the time it is written the grid is
-- the locked race grid) and wrong here. Qualifying is scored the moment the
-- session ends, and at that moment a driver's grid slot is where they STARTED
-- qualifying -- so scoring off it would pay out the order the session began in.
--
-- Drivers with no lap are left out entirely rather than sorted to the back:
-- they did not qualify, and there is no position to pay them for.
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

-- Qualifying just ended. Work out the qualifying points and HOLD them: they are
-- banked by the race that follows, as part of that round.
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

-- Pay out every bonus belonging to one discipline.
--
-- Shared by both scorers, and it walks only the registry entries whose `kind`
-- matches -- so a derby can never be handed a fastest-lap bonus and a race can
-- never be handed a last-man-standing one. A bonus set to zero costs a table
-- lookup and pays nothing, which is how the whole set stays inert until an
-- admin turns one on.
--
-- `byPid` maps a player id to the round row being written for them, so an
-- award naming a driver who was not scored (already gone, never entered) simply
-- finds nothing and is dropped.
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

  -- Position points.
  --
  -- A classified finisher scores for where they finished. A disqualification
  -- scores nothing, always -- that is what the penalty is. A DNF depends on the
  -- league's dnfScoring rule (see the scoring table): nothing, its place in the
  -- classification, or the place it was running in when it stopped.
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
        -- The place they were RUNNING IN, which is what "held" means and is a
        -- different fact from where they classify. Falls back to the
        -- classification when the driver stopped before a running order existed:
        -- there is no held position to honor then.
        scorePos = rec.heldPos or rec.dnfPos or i
      end
    end
    local entry = cupEntryFor(rec)
    if entry then
      local pending = cupPendingFor(entry.entryId)
      local row = {
        kind     = 'race',
        round    = round,
        -- Only a real finish counts as a finishing position (and so as a win).
        -- A DNF paid under 'held' is scored at a position; it did not take it.
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

-- A derby ended. Banks one round, on the derby side of the cup.
--
-- `classification` is the finished order the derby module handed over: the
-- winner first, then anyone still running, then the eliminated in reverse order
-- of elimination -- surviving longer is finishing higher. That IS the result of
-- a derby, which is the one place derby scoring genuinely differs from a race:
--
--   * in a race, a driver who did not finish scores nothing, because not
--     finishing is a failure to produce a result;
--   * in a derby, being eliminated is the normal way to end and the position it
--     produces is the result. Everybody in the classification scores.
--
-- The winner is distinct from finishing first: a derby can end with nobody left
-- alive, and then the driver who lasted longest tops the table without having
-- won it. Only a real survivor carries `status == 'winner'`.
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
      -- `classified` is what the fastest-lap rule reads, and it is a race
      -- concept; every derby row is a real result, so it is simply true here.
      byPid[rec.id] = { entry = entry, row = row, classified = true }
      scored = scored + 1
    end
  end

  cupAwardBonuses('derby', { winnerPid = winnerPid, duration = info and info.duration }, byPid)

  cup.round = round
  -- A derby does not consume held qualifying points: those belong to a RACE
  -- round, and a derby run between qualifying and its race must not eat them.
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

-- THE entry points, filling the forward declarations beside the entry list.
-- One call at the end of finishSession for each kind of session, one at the end
-- of finishDerby, and one boolean test when no cup is running.
--
-- Returns the round number a RACE banked, so the results file written moments
-- later can report that round specifically (see cupResultsLines). Qualifying
-- banks no round -- its points are held for the race that follows -- and
-- returns nothing, which is also what a cup that is switched off or at its
-- round cap returns.
cupOnSessionComplete = function (kind)
  if not getCup().enabled then return nil end
  if kind == 'quali' then
    cupScoreQuali()
    return nil
  end
  return cupScoreRace()
end

-- The round just banked, as lines for the results file.
--
-- This is the cup being READ rather than told, and it is the only call that
-- goes that way. It stays inside the module's rules all the same: it is called
-- from the two results writers, after the classification is final and the round
-- is scored, so nothing cup-shaped runs while cars are on track. It computes
-- nothing new -- the numbers are the ones already banked and the order is
-- cupStandings' own.
--
-- `round` is the round the finished session actually banked, handed down from
-- finishSession (or finishDerby) rather than read from cup.round here. Those
-- differ in exactly the case that matters: a cup at the round cap scores
-- nothing, and asking for "the current round" would then print the PREVIOUS
-- event's points onto this one's results file.
--
-- Returns nil when there is nothing to say, which is the normal case: no cup
-- running, nothing banked, or a round nobody scored in. A race night without a
-- championship gets exactly the results file it always got.
cupResultsLines = function (round)
  if not getCup().enabled or not round then return nil end

  -- What each driver took out of THIS round, keyed by entry. Read off the round
  -- rows the scoring wrote; a driver with no row simply did not score here.
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
  -- One table, ordered by championship position after this round. It answers
  -- both questions a league asks of a results file -- what did each driver score
  -- today, and where does that leave them -- without printing the same field
  -- twice in two orders.
  add(string.format('%-5s %-22s %-6s %-6s %-6s %-7s %s',
    'Pos', 'Driver', 'Race', 'Quali', 'Bonus', 'Round', 'Total'))
  for _, s in ipairs(cupStandings()) do
    local r = roundBy[s.entryId]
    local racePts  = r and (tonumber(r.racePts) or 0) or 0
    local qualiPts = r and (tonumber(r.qualiPts) or 0) or 0
    local bonusPts = r and bonusOf(r) or 0
    local roundPts = racePts + qualiPts + bonusPts
    -- A driver who was not in this round is shown with dashes rather than
    -- zeroes: not scoring and not being there are different facts, and a column
    -- of noughts against a name that never appeared reads as the first.
    add(string.format('P%-4d %-22s %-6s %-6s %-6s %-7s %d',
      s.pos, s.name,
      r and tostring(racePts)  or '-',
      r and tostring(qualiPts) or '-',
      r and tostring(bonusPts) or '-',
      r and tostring(roundPts) or '-',
      s.total))
  end
  -- Which bonuses were paid, and to whom. The table above can only show a total,
  -- and "+2" against a name does not say what it was for -- the one question
  -- somebody checking a championship a month later will actually have.
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
  -- Adjustments are part of a total and are invisible in it. A standings table
  -- nobody can take apart is a standings table nobody can check.
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

-- Returns the round a derby banked, on the same contract cupOnSessionComplete
-- follows: nil when nothing was scored, which includes a cup that does not pay
-- for derbies at all.
cupOnDerbyComplete = function (classification, info)
  if not getCup().enabled then return nil end
  -- An empty derby points table means derbies are not part of THIS cup, and it
  -- means it completely: no round is banked and no derby bonus is paid.
  --
  -- The alternative -- an empty position table with the bonuses left live -- is
  -- the shape of trap that gets noticed three rounds later. An admin who presses
  -- "Turn derby points off" has said derbies do not count here, and a survivor
  -- quietly collecting a last-man-standing bonus afterwards would contradict
  -- them. Same rule qualifying already follows.
  if #cup.scoring.derby == 0 then return nil end
  if type(classification) ~= 'table' or #classification == 0 then return nil end
  return cupScoreDerby(classification, info)
end

-- ---------------------------------------------------------------------------
-- Admin events
-- ---------------------------------------------------------------------------
-- No UI reaches these yet: the controls arrive with the cup panel, and until
-- then the server console is the feedback. They are registered and complete so
-- the whole module is exercisable exactly the way every other handler in this
-- file is tested -- by calling it.
function RM_onCupSetEnabled(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup().enabled = data.enabled == true or data.enabled == 1
  saveCupToDisk()
  print('[RaceManager] Cup points ' .. (cup.enabled and 'ENABLED' or 'disabled')
    .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Start a NEW cup: everything a previous one accumulated goes, which is why
-- this is separate from enabling scoring. Continuing an existing cup is simply
-- not pressing it.
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

-- End the cup and clear its points. THE only thing that clears them -- a race
-- reset, a phase change and a restart all leave a cup exactly where it was.
--
-- The roster is untouched: display names are not cup property, and an admin who
-- ends a championship has not asked to re-name their whole grid.
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

-- Load a preset into one of the two points tables. `target` picks which; it
-- defaults to the race table, so a client that does not send one behaves the
-- way it did before derbies could be scored.
function RM_onCupSetPreset(pid, rawData)
  if not requireAuth(pid) then return end
  local key = decodeString(rawData, 'preset')
  local preset = key and cupAnyPresetByKey(key)
  if not preset then
    print('[RaceManager] Unknown cup scoring preset: ' .. tostring(key))
    return
  end
  local target = decodeString(rawData, 'target') == 'derby' and 'derby' or 'race'
  getCup()
  if target == 'derby' then
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

-- Save the race table as a named system, so an evening spent agreeing a points
-- structure survives the cup it was agreed during.
--
-- The RACE table specifically, and only that one. A "system" here is one table:
-- quali and derby have Same as race for the case where a league wants them
-- alike, and their own line for when it does not. Saving all three as a bundle
-- would need a bundle format, a merge rule, and an answer for what happens when
-- you load one over a cup that only uses two of them.
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
  -- Namespaced, so a saved system can never collide with a built-in key and an
  -- admin cannot shadow "25P Moderate" with something that is not it.
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

-- Delete a saved system. Built-ins are not deletable and saying so beats
-- silently doing nothing.
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

-- Custom scoring. Every field is optional, so the UI can send just the part the
-- admin edited; anything present replaces that part outright.
function RM_onCupSetScoring(pid, rawData)
  local data = adminPayload(pid, rawData)
  if not data then return end
  getCup()
  local touched = false
  if type(data.race) == 'table' then
    cup.scoring.race = cupSanitizeTable(data.race)
    -- Hand-edited: it is no longer any of the presets, and saying so is what
    -- stops the UI showing "30P Aggressive" over a table that is not it.
    cup.scoring.preset = 'custom'
    touched = true
  end
  if type(data.derby) == 'table' then
    cup.scoring.derby = cupSanitizeTable(data.derby)
    cup.scoring.derbyPreset = 'custom'
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
    .. ', quali '
    .. (#cup.scoring.quali > 0 and (#cup.scoring.quali .. ' deep') or 'off') .. ')')
end

-- Fold one cup entry into another, filling the forward declaration the roster
-- makes. Called when a provisional entry turns out to have been a driver the
-- admin can name: the rounds and adjustments move, the placeholder goes.
--
-- Rounds are appended rather than merged by round number. A driver can only
-- have raced one of them, so there is nothing to reconcile -- and if a cup ever
-- does end up with two rows for one round, an admin can see both and drop one,
-- which is a better outcome than this silently picking a winner.
-- Qualifying points are HELD between the session that scored them and the race
-- that banks them, keyed on the entry they were scored against. A driver
-- identified in that window changes entry, so the held row has to come with
-- them -- it is looked up by entry id, and a stale one is simply never found
-- again, which reads as the driver having qualified for nothing.
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
    -- Nothing to merge into yet: the entry simply changes hands. Its points
    -- were earned by this driver either way.
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
-- Assign a connected player to a roster entry. This is how a driver gets their
-- name -- and their points -- back after a reconnect, and it is an admin action
-- because nothing else can know: BeamMP hands out a fresh random guest name
-- every join, so the server cannot tell a returning regular from a stranger.
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

  -- entryId 0 (or absent) means "unassign": drop the binding and the name, and
  -- leave the entry -- and everything on it -- where it is.
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

-- Delete a roster entry outright, and everything the cup holds against it.
-- The way to clear out placeholders left by drivers who never came back.
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

-- ---------------------------------------------------------------------------
-- Manual adjustments
-- ---------------------------------------------------------------------------
-- An admin has to be able to correct a cup by hand. Drivers disconnect, a race
-- gets administered badly, a penalty is agreed after the fact -- and a scoring
-- system with no way to say "minus five, track limits" is one an admin has to
-- work around by rescoring an entire round.
--
-- Adjustments are kept as a LEDGER, separate from the points a driver earned,
-- and never folded into them. A total that cannot be taken apart is a total
-- nobody can check: the standings show what was earned and what was adjusted as
-- two numbers, and every adjustment keeps its reason, its author and its time.
--
-- Removing an adjustment deletes the entry rather than posting an opposite one,
-- because a mistake in the ledger is not an event that happened.
local MAX_ADJUST      = 9999
local MAX_ADJUST_NOTE = 60

local function cupCleanNote(raw)
  local s = tostring(raw or ''):gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
  -- Same character class the display names use, and for the same reason: this
  -- text reaches a fixed-width results export and the server console.
  s = s:gsub('[^%w %-%_%.%,%:%(%)/]', '')
  return s:sub(1, MAX_ADJUST_NOTE)
end

-- Adjust one driver's total. A positive delta adds points, a negative one takes
-- them away. Identified by cup entry id -- the roster entry -- so an adjustment
-- lands on the driver and not on whoever happens to hold a session id.
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

-- Drop a whole round from a driver's record.
--
-- The honest way to fix a race that was scored wrongly: remove the round and
-- run it again, rather than posting a compensating adjustment that leaves the
-- breakdown describing something that never happened. The cup's round COUNT is
-- deliberately left alone -- the event did take place, and renumbering every
-- later round to close the gap would rewrite history to hide a correction.
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

-- The last thing the installer does: hand the two lazy loaders out to onInit,
-- which warms them at boot the way it warms the layouts, the garage and the
-- saved arenas.
rosterWarm, cupWarm = getRoster, getCup

end
installRosterAndCup()

-- The derby scores into the cup, and the cup does not exist until the line
-- above has RUN -- both of these are nil until then, which is why they cannot
-- go through derbyMod.init.
--
-- It has to be here, after the call, not after the definition. The first
-- version of this line landed inside installRosterAndCup's body by matching
-- its `local function` line, so it handed the derby two nils and the cup
-- stopped scoring derbies. cup_test caught it.
derbyMod.setCupHooks(cupOnDerbyComplete, cupResultsLines)

-- ===========================================================================
-- End of CUP module
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
  race.time = race.time + CFG.tickMs / 1000.0
  -- The hold at the flag. Checked before anything else in the tick: once it
  -- expires there is no session left for the rest of this function to run.
  if race.endsAt and race.time >= race.endsAt then
    local reason = race.endReason or 'race over'
    race.endsAt, race.endReason = nil, nil
    finishSession(reason)
    return
  end
  -- THE GRACE, and it is one rule for both session kinds now. Once the flag is
  -- out, a driver with no crossing left to give -- parked in the pits, stuck in
  -- a barrier, never left the grid -- must not hold the session open forever.
  -- Qualifying has always done this; a timed race reaches the same state by a
  -- different route and needs the same valve on it.
  if race.finalLap then
    race.finalLapLeft = race.finalLapLeft - CFG.tickMs / 1000.0
    if race.finalLapLeft <= 0 then
      local stranded = {}
      for _, rec in pairs(players) do
        if onTrack(rec) then stranded[#stranded + 1] = rec end
      end
      -- Snapshot first: retireDriver sends a client event per driver, and
      -- building the list while that is going on is the shape of bug that
      -- reached only the last name in it.
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
      -- Not a return: the session is still running, and the broadcast below
      -- is what carries the final-lap flag to every client.
    end
  elseif race.phase == 'racing' and race.raceTimeLimit > 0 then
    if not race.raceExpired then
      -- THE CLOCK RUNNING OUT CHANGES NOTHING YET. It arms the wait; the
      -- leader's next crossing is what starts the final lap. A driver reading
      -- laps-to-go sees two at this point: finish this one, then run the last.
      if race.time >= race.raceTimeLimit then
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
      -- NO LEAD-LAP CROSSING SINCE THE CLOCK EXPIRED, for longer than a lap has
      -- any business taking. The leader retired, or the field is stopped, and
      -- the crossing this format waits on is never going to arrive. The flag
      -- goes out directly: everyone still running is classified as they come
      -- past, which is the same ending a lapped car always gets.
      race.finalLap     = true
      race.finalLapLeft = CFG.finalLapGrace
      broadcastState()
      MP.SendChatMessage(-1, '[RaceManager] CHECKERED FLAG: no leader crossing since the '
        .. 'clock expired. Everyone still out is classified as they cross.')
      print('[RaceManager] Timed race: no lead-lap crossing within the grace, flag out')
    end
  end
  tickCounter = tickCounter + 1
  if tickCounter >= CFG.pushEveryTicks then
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
  -- the pre-existing behavior Generate Grid purges.
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
      existing.spectating = false
      -- A different person now holds this id, so whatever the departed player
      -- was bound to in the roster is emphatically not theirs.
      if rosterUnbind then rosterUnbind(pid) end
      rememberIdentity(existing)
    end
  end
  local rec = ensurePlayer(pid)
  if not rec then return end
  -- Connecting is not entering: in the default opt-in mode a new arrival is a
  -- spectator until they press Join Race. In 'all' mode they are in the field
  -- straight away, which is what that mode means.
  --
  -- BUT NOT INTO A SESSION THAT IS ALREADY RUNNING. Somebody who connects
  -- mid-race has no grid slot, no laps and no out lap behind them; putting them
  -- on the timing screen as a participant makes a nonsense of the classification
  -- and, in 'all' mode, did exactly that. They are a bystander until the next
  -- grid forms, which is where every entry decision is read.
  --
  -- rec.bystander is what the CLIENTS act on: it ghosts that car for everyone,
  -- so a driver arriving in the middle of a race cannot put anyone into a wall
  -- before they have worked out what is going on.
  if sessionUnderWay() or race.derbyUnderWay() then
    rec.status    = 'waiting'
    rec.bystander = true
    MP.SendChatMessage(pid, '[RaceManager] A session is already running: you are '
      .. 'a spectator until it ends, and your car is a ghost so you cannot '
      .. 'interfere with it.')
    print(string.format('[RaceManager] %s joined mid-session: bystander + ghosted',
      rec.name))
  elseif race.phase == 'qualifying' and isEntrant(rec) then
    rec.status = 'qualifying'
  end
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  pid = pidKey(pid)
  if not pid then return end
  -- Session IDs are reused, so a disconnecting admin must drop its auth flag;
  -- the next player to inherit this ID starts with no admin rights.
  local wasAdmin = authenticatedPlayers[pid] ~= nil
  authenticatedPlayers[pid] = nil
  -- Their car is going with them, so the ghost on it has to go too. Unclearing
  -- this matters more than it looks: session ids are REUSED, so a ghost left
  -- against a departed player is inherited by the next person to be handed that
  -- id, who would arrive already intangible and with no way to end it -- the
  -- client that could run the occupancy check for it has gone.
  clearGhost(pid, 'player disconnected')
  -- The binding is a live association between a connection and a roster entry,
  -- so it goes with the connection. The ENTRY stays, with every point it has
  -- earned -- that is the whole reason it lives on disk.
  if rosterUnbind then rosterUnbind(pid) end
  local rec = players[pid]
  if not rec then
    -- Non-racer admin (e.g. a spectating host) left: still refresh adminPresent.
    if wasAdmin then broadcastState() end
    return
  end
  if onTrack(rec) or rec.status == 'gridded' then
    retireAsDnf(rec, 'DNF - Disconnected')
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
  -- SETTINGS FIRST, before any of it is read. The race table below was seeded
  -- from CFG when the file loaded, so anything config.json overrides has to be
  -- pushed into the live state as well -- see applyConfigToRace.
  loadConfigFromDisk()
  applyConfigToRace()
  MP.RegisterEvent('RM_Login',            'RM_onLogin')
  MP.RegisterEvent('RM_Logout',           'RM_onLogout')
  MP.RegisterEvent('RM_ChangePassword',   'RM_onChangePassword')
  MP.RegisterEvent('RM_StartQualifying',  'RM_onStartQualifying')
  MP.RegisterEvent('RM_GenerateGrid',     'RM_onGenerateGrid')
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
  MP.RegisterEvent('RM_SetGarageEnforce', 'RM_onSetGarageEnforce')
  MP.RegisterEvent('RM_SetGarageMode',    'RM_onSetGarageMode')
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
  MP.RegisterEvent('RM_SetLayoutPractice','RM_onSetLayoutPractice')
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
  -- Cup / series points (isolated module; see the CUP section). No client sends
  -- these yet -- the admin panel comes with the UI work -- but the handlers are
  -- registered so the module is complete and reachable the moment it does.
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
  MP.RegisterEvent('RM_CupForgetDriver',  'RM_onCupForgetDriver')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', CFG.tickMs)
  -- Boot from a clean slate: any client still connected across a plugin
  -- reload drops its stale gates, then the layout cache is re-warmed from disk.
  clearTrackState('server startup')
  getLayouts()       -- warm the layout cache so saved tracks survive the restart visibly
  getGarage()        -- and the approved vehicle list (Module 4)
  derbyMod.getDerbyLayouts()  -- and the saved derby arenas
  rosterWarm()       -- and the display names an admin has already assigned
  cupWarm()          -- and a cup left running when the server went down
  print('[RaceManager] Server plugin loaded (build ' .. RM_BUILD
    .. ', circuit edition, map: ' .. getCurrentMap() .. ')')
end
