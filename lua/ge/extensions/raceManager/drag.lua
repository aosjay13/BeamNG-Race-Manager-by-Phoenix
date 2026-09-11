-- Race Manager: DRAG RACING, as its own module.
--
-- The client half of the tournament ladder in server/RaceManager/drag.lua. The
-- server owns the bracket; this file owns the two things only a client can do,
-- because only a client has the physics:
--
--   * RUN THE CHRISTMAS TREE, locally, on this machine's clock
--   * MEASURE THE PASS: reaction time, elapsed time, trap speed, and whether
--     the car left before the green
--
-- WHY THE TREE RUNS HERE. A reaction time is the gap between a light coming on
-- and a car moving, and it is decided in the third decimal place. Timing that
-- against a server tick would measure the network instead: the driver furthest
-- from the box would post the worst light however well they drove. So the
-- server sends the SHAPE of the tree -- which pattern, the pre-roll it drew,
-- and this lane's handicap -- and every client runs the same lights against its
-- own clock. Same trade the lap timer already makes, for the same reason.
--
-- THE HANDICAP IS THE WHOLE TREE, not a hold after the green. In bracket racing
-- the slower car's tree runs first and the quicker car's starts later by the
-- difference between the two dial-ins, so a driver watches an ordinary tree and
-- launches on their own green. Delaying only the green would show somebody a
-- three-amber sequence and then not let them go, which is the one thing a
-- staged driver cannot be asked to ignore.
--
-- THE CONTRACT is the derby's. Nothing here reaches back into the extension by
-- name: plain functions are called off the host table, mutable scalars come
-- through GETTERS (a value captured at init would be a snapshot of load time),
-- and tables come by reference.
--
-- TWO EXCEPTIONS, AND THEY ARE THE SAME EXCEPTION. The route and the start
-- positions come through GETTERS rather than by reference, because
-- `track.route` and `track.startPositions` are REASSIGNED when a layout loads
-- rather than cleared in place -- so a reference taken here at init goes on
-- pointing at whatever table the mod started with, forever.
--
-- The second of those was learned the expensive way: the lanes were passed by
-- reference under a comment asserting the table was cleared in place, and
-- every staged car was placed against the empty one the mod booted with. It
-- reads as "Start position 1 is not placed on this track" on a strip that
-- plainly has two, which points at the track editor and not at this file.
--
-- Which fields are which is not something anybody can be expected to remember,
-- so tests/wiring_test.lua checks it: a module init may not take a `track`
-- field by reference if the host ever reassigns it.

local D = {}
local host

function D.init(h)
  host = h
end

-- ===========================================================================
-- Tunables
-- ===========================================================================
-- How far the car has to move off its staged position before it counts as
-- having launched. Half a meter: far enough that suspension settle, a shunt
-- from the lane alongside and the physics jiggle a frozen car does on release
-- do not read as a start, and short enough that the reaction time it stamps is
-- still the moment the driver went.
local DRAG_LAUNCH_DIST = 0.5
-- Three ambers together, green four tenths later. The professional tree.
local DRAG_PRO_LIGHTS  = 0.4
-- Ambers half a second apart, green half a second after the last. The
-- sportsman (or full) tree, which is what most brackets run.
local DRAG_SPORT_STEP  = 0.5
local DRAG_SPORT_LIGHTS = DRAG_SPORT_STEP * 3
local MPS_TO_MPH = 2.236936
-- HOW LONG THE TIME SLIP STAYS UP.
--
-- It is a RESULT, not a state, and it was written as though it were a state:
-- pushed once when the pass ended and left on screen for ever. It outlived the
-- pass, the ladder and the tab -- an admin on the Race tab was still being
-- shown somebody's elapsed time from twenty minutes earlier, over a panel that
-- had nothing to do with it.
--
-- Long enough to drive back and read it, short enough that it is gone before
-- it is a lie. Every path that means "there is no run to show" clears it early
-- (see clearSlip); this is the backstop for the ones nobody thought of, which
-- is what the original was missing.
local DRAG_SLIP_SECONDS = 25

-- ONE TABLE, not fifteen file-scope locals. Same discipline as everywhere else
-- in this mod: Lua caps a function at 200 locals, the top level of a file is a
-- function, and going over does not warn -- the file fails to compile and the
-- mod is simply not there.
D.dragState = {
  phase   = 'idle',     -- mirrored from the server
  lane    = nil,        -- which lane this driver is in, or nil for a spectator
  dial    = nil,
  delay   = 0,          -- this lane's handicap, in seconds
  -- THE RUN IN PROGRESS. Everything below is measured locally and reset for
  -- every pass; a field left over from the last one is the whole class of bug
  -- the server's note on derby.endsAt describes.
  running  = false,
  t        = 0,         -- seconds since the tree was dropped
  treeAt   = nil,       -- t this driver's own lights start
  greenAt  = nil,       -- t this driver's own green comes on
  timeoutAt = nil,      -- t this driver gives up and reports no time
  anchor   = nil,       -- where the car was staged
  prevPos  = nil,       -- last sampled position, for the finish line test
  launchAt = nil,       -- t the car left the anchor
  released = false,     -- the hold has come off for this pass
  foul     = false,     -- left before the green
  reported = false,     -- a result has gone to the server
  stage    = 'off',     -- what the tree is showing: off|staged|amber1..3|green|red
  pattern  = 'sportsman',
  -- ROLLING UP INTO THE BEAMS. Under this mode the car is placed BEHIND the
  -- line and left free, and the driver creeps forward until the bulbs light.
  -- `line` is the start position the beams are measured against, and the
  -- three thresholds arrive with it from the server so both halves agree on
  -- where the beams are.
  rollup    = false,
  line      = nil,      -- { x, y, hx, hy } the beams are measured from
  preAt     = -1.2,
  stageAt   = -0.35,
  pastAt    = 2.0,
  preStaged = false,
  inBeams   = false,
  -- The last pass this driver made, held so the HUD can show it after the
  -- lights have gone out, and the seconds it has left to live.
  lastRT = nil, lastET = nil, lastSpeed = nil,
  slipLeft = 0,
  -- A spectator's copy of the tree, so everybody watching sees the same lights
  -- come on as the cars on the line.
  watching = false,
}

local S = D.dragState

local function lightsFor(pattern)
  return pattern == 'pro' and DRAG_PRO_LIGHTS or DRAG_SPORT_LIGHTS
end

-- The lights, as the panel draws them. The two blue bulbs are sent separately
-- from the amber sequence because under roll-up they are a different fact: an
-- amber is a moment in a countdown, a stage bulb is where the car is standing.
local function pushTree(stage, force)
  if S.stage == stage and not force then return end
  S.stage = stage
  guihooks.trigger('RaceManagerDragTree', {
    stage = stage, lane = S.lane, dial = S.dial, delay = S.delay,
    prestaged = S.preStaged, staged = S.inBeams, rollup = S.rollup,
  })
end

-- Wind the whole local run down. Called from every path that can end one: the
-- result being reported, an abort, the pass leaving 'running' on the server,
-- and the driver's own timeout.
local function endRun(stage)
  S.running  = false
  S.released = false
  S.rollup, S.line = false, nil
  S.preStaged, S.inBeams = false, false
  S.treeAt, S.greenAt, S.timeoutAt = nil, nil, nil
  S.anchor, S.prevPos, S.launchAt = nil, nil, nil
  pushTree(stage or 'off')
end

-- THE HOLD COMES OFF AT THE FIRST LIGHT OF THIS DRIVER'S OWN TREE, and the
-- anchor the launch is measured from is taken at the same instant.
--
-- Both used to happen when the tree message arrived, which is the moment the
-- admin pressed Run -- and that is too early on two counts. The car may still
-- be LANDING: placement is staggered at 0.18s a lane so an eight-wide field is
-- still arriving 1.26s after Stage, and an anchor taken mid-flight is half a
-- strip away from where the car ends up, which reads as a launch on the next
-- frame and hands the driver a red light they never earned. And releasing a
-- car the placement queue is about to freeze leaves it frozen for the whole
-- pass, because the queue applies its hold after this let it go.
--
-- The pre-roll is what covers both, which is why its floor is 1.5s rather than
-- a rounder number: that is longer than the widest field takes to land. The
-- check below is the belt to that braces -- if a placement really is still
-- running, the release waits a frame, and never past the green.
local function releaseForLaunch()
  if S.released then return end
  local landing = host.placementActive and host.placementActive()
  if landing and S.t < (S.greenAt or 0) then return end
  local _, pos = host.sampledVehicle()
  S.released = true
  -- UNDER ROLL-UP THE ANCHOR IS ALREADY SET, at the stage beam, and moving it
  -- now would be moving the start line under a car that may already be
  -- leaving. Only take a fresh one when there is none -- a held car, or a
  -- roll-up car the courtesy stage timed out on before it ever staged.
  if not S.anchor then
    S.anchor = pos and { x = pos.x, y = pos.y, z = pos.z } or nil
  end
  S.prevPos = S.prevPos or pos
  host.releaseGridHold('drag')
end

-- Take the time slip down. Pushed to the panel rather than only cleared here,
-- because the panel is what is showing it.
local function clearSlip()
  if S.slipLeft <= 0 and S.lastET == nil and S.lastRT == nil then return end
  S.slipLeft = 0
  S.lastRT, S.lastET, S.lastSpeed = nil, nil, nil
  guihooks.trigger('RaceManagerDragRun', { clear = true })
end

local function slipUpdate(dt)
  if S.slipLeft <= 0 then return end
  S.slipLeft = S.slipLeft - dt
  if S.slipLeft <= 0 then clearSlip() end
end

local function reportResult(et, speed)
  if S.reported then return end
  S.reported = true
  local rt = nil
  if S.launchAt and S.greenAt then rt = S.launchAt - S.greenAt end
  S.lastRT, S.lastET, S.lastSpeed = rt, et, speed
  if host.inMultiplayer() then
    local parts = {}
    if rt    then parts[#parts + 1] = string.format('"rt":%.4f', rt) end
    if et    then parts[#parts + 1] = string.format('"et":%.4f', et) end
    if speed then parts[#parts + 1] = string.format('"speed":%.2f', speed) end
    if S.foul then parts[#parts + 1] = '"foul":true' end
    TriggerServerEvent('RM_DragResult', '{' .. table.concat(parts, ',') .. '}')
  end
  -- The driver's own numbers, on their own screen, the moment they have them.
  -- The board will agree a beat later; this is the one that is there when they
  -- look up.
  if et then
    host.pushNotice('drag', string.format('%s  RT %.3f  ET %.3f  %.1f mph',
      S.foul and 'RED LIGHT' or 'PASS COMPLETE', rt or 0, et, speed or 0))
  else
    host.pushNotice('drag', 'No time: the pass ran out of road.')
  end
  S.slipLeft = DRAG_SLIP_SECONDS
  guihooks.trigger('RaceManagerDragRun', {
    rt = rt, et = et, speed = speed, foul = S.foul, lane = S.lane,
  })
  endRun(S.foul and 'red' or 'off')
end

-- HOW FAR THIS CAR IS FROM THE BEAMS, in metres along the line's heading.
--
-- Signed, and the sign is the whole of it: negative is short of the line,
-- zero is on it, positive is past. Projected onto the heading rather than
-- measured as a straight-line distance, because a car sitting a metre to one
-- side in its own lane is exactly as staged as one dead centre -- and a plain
-- distance would call it a metre short.
local function beamDistance(pos)
  if not (S.line and pos) then return nil end
  local dx, dy = pos.x - S.line.x, pos.y - S.line.y
  return dx * (S.line.hx or 0) + dy * (S.line.hy or 1)
end

-- Creeping into the beams. Runs only while the pass is staging under roll-up:
-- once the tree is going the bulbs are frozen at whatever they said, because
-- the car is about to leave them and that is a launch, not an un-stage.
local function stagingUpdate()
  if not (S.rollup and S.line) or S.running then return end
  local _, pos = host.sampledVehicle()
  local d = beamDistance(pos)
  if not d then return end
  local pre = d >= S.preAt and d <= S.pastAt
  local inb = d >= S.stageAt and d <= S.pastAt
  -- THE LAUNCH IS MEASURED FROM THE STAGE BEAM, so the anchor is taken here
  -- and not when the lights start.
  --
  -- It used to be taken at the first amber, which is correct under 'hold' --
  -- the car is frozen until then and cannot have moved -- and wrong under
  -- roll-up, where the car has been free since it was placed. A driver who
  -- left during the pre-roll had no anchor to be measured against, so the
  -- foul was never seen AND the anchor was then taken from wherever they had
  -- got to, timing the run from a rolling start.
  --
  -- Kept current while the car sits in the beams, because staging deeper is a
  -- thing drivers do on purpose, and frozen the instant the tree starts:
  -- stagingUpdate does not run while the pass is running.
  if inb and pos then S.anchor = { x = pos.x, y = pos.y, z = pos.z } end
  if pre == S.preStaged and inb == S.inBeams then return end
  S.preStaged, S.inBeams = pre, inb
  -- ON CHANGE ONLY. Two booleans at sixty hertz is sixty times the traffic
  -- for a fact that moves twice a pass.
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DragStaged', string.format(
      '{"prestaged":%s,"staged":%s}',
      pre and 'true' or 'false', inb and 'true' or 'false'))
  end
  pushTree('staged', true)
end

-- ===========================================================================
-- The frame
-- ===========================================================================
-- Everything a drag pass measures happens here, and it does nothing at all
-- unless this client is in the pass. A driver watching from the fence runs the
-- spectator tree below and nothing else.
function D.dragUpdate(dt)
  -- BEFORE EVERY EARLY RETURN BELOW, and that is the point: the slip has to
  -- expire whatever else this client is or is not doing. The frame is the only
  -- thing that runs unconditionally.
  slipUpdate(dt)
  if S.watching and not S.running then
    -- Spectator tree: the lights, and nothing that touches a car.
    S.t = S.t + dt
    local base = S.treeAt or 0
    if S.t < base then pushTree('staged')
    elseif S.greenAt and S.t >= S.greenAt then
      pushTree('green')
      if S.t > (S.greenAt + 3) then S.watching = false; endRun('off') end
    else
      local step = (S.t - base)
      if S.pattern == 'pro' then pushTree('amber3')
      elseif step >= DRAG_SPORT_STEP * 2 then pushTree('amber3')
      elseif step >= DRAG_SPORT_STEP     then pushTree('amber2')
      else pushTree('amber1') end
    end
    return
  end
  -- Creeping up to the line, before any of the timing exists.
  if not S.running then stagingUpdate(); return end
  S.t = S.t + dt
  if not S.released and S.t >= (S.treeAt or 0) then releaseForLaunch() end

  -- The lights, on this driver's own tree.
  --
  -- NOT ONCE FOULED. The launch below turns the bulb red, and this block runs
  -- first on every later frame -- so during the pre-roll it put 'staged' back
  -- over the top and the red light was visible for exactly one frame. A red
  -- light stays red for the rest of the run, which is what the tree at a strip
  -- does and what the driver has to be able to see.
  if not S.reported and not S.foul then
    if S.t < (S.treeAt or 0) then
      pushTree('staged')
    elseif S.t >= (S.greenAt or 0) then
      pushTree(S.foul and 'red' or 'green')
    else
      local step = S.t - (S.treeAt or 0)
      if S.pattern == 'pro' then pushTree('amber3')
      elseif step >= DRAG_SPORT_STEP * 2 then pushTree('amber3')
      elseif step >= DRAG_SPORT_STEP     then pushTree('amber2')
      else pushTree('amber1') end
    end
  end

  local veh, pos = host.sampledVehicle()
  if not veh or not pos then return end

  -- LAUNCH. Measured as distance off the staged position rather than as speed,
  -- because a car being shunted sideways on the line is not a launch and a car
  -- creeping forward at walking pace is.
  if not S.launchAt and S.anchor then
    local dx, dy = pos.x - S.anchor.x, pos.y - S.anchor.y
    if (dx * dx + dy * dy) >= (DRAG_LAUNCH_DIST * DRAG_LAUNCH_DIST) then
      S.launchAt = S.t
      -- A RED LIGHT IS A FOUL, NOT A CANCELLED PASS. The driver goes on down
      -- the strip and still puts an ET on the board; the server decides what a
      -- foul costs them. Deciding it here would let a client decide it did not
      -- happen.
      if S.t < (S.greenAt or 0) then
        S.foul = true
        pushTree('red')
        host.pushNotice('drag', 'RED LIGHT - you left before the green.')
      end
    end
  end

  -- THE FINISH LINE IS THE LAST GATE OF THE LOADED LAYOUT, which is what makes
  -- a point-to-point sprint stage a drag strip without a second editor. The
  -- crossing test is the same one the lap timer uses.
  if S.launchAt and S.prevPos then
    local gate = host.finishGate()
    if gate and host.segmentCrossesGate(gate, S.prevPos, pos) then
      local speed = nil
      local ok, vel = pcall(function () return veh:getVelocity() end)
      if ok and vel then
        speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) * MPS_TO_MPH
      end
      reportResult(S.t - S.launchAt, speed)
      return
    end
  end
  S.prevPos = pos

  -- Gave up. Reported rather than left to the server's own timeout, so a pass
  -- settles the moment the last car stops trying instead of a minute later.
  if S.timeoutAt and S.t >= S.timeoutAt then
    reportResult(nil, nil)
  end
end

-- ===========================================================================
-- Server -> client
-- ===========================================================================
D.onDragUpdate = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not host.fromCurrentServer(data) then return end
  local newPhase = data.dragPhase or 'idle'
  -- A PASS THAT IS NO LONGER RUNNING RELEASES EVERY CAR IT HELD, whatever order
  -- the broadcasts arrive in. Without this a client that missed the abort would
  -- sit frozen on the line for the rest of the evening.
  if newPhase ~= 'staging' and newPhase ~= 'tree' and newPhase ~= 'running' then
    -- NOT GATED ON S.running, and that is the fix rather than the tidy: a red
    -- light ends the local run the moment it is reported, so by the time the
    -- pass settles S.running is already false and a gate here left the red bulb
    -- burning on screen with nothing left to turn it off.
    if S.running or S.watching or S.stage ~= 'off' then
      S.watching = false
      endRun('off')
    end
    if S.phase == 'staging' or S.phase == 'tree' or S.phase == 'running' then
      host.releaseGridHold('drag')
      S.lane, S.delay = nil, 0
    end
    -- THE LADDER IS GONE, so the slip goes with it. This is the path Clear
    -- Ladder takes, and it is also the only one available after a practice
    -- pass: that leaves the phase at 'idle', where the Clear Ladder button is
    -- disabled and cannot be the thing that tidies up.
    if newPhase == 'idle' then clearSlip() end
  end
  S.phase = newPhase
  -- WHICH ROW IS MINE. The board arrives as one broadcast to the whole server,
  -- so it cannot be addressed to anybody; the id comparison happens here,
  -- where this client's own id is actually known. Without it the panel has no
  -- way to offer a driver their own dial-in box.
  local me = host.localServerId()
  if me and type(data.entrants) == 'table' then
    for _, row in ipairs(data.entrants) do
      row.you = (row.id ~= nil and row.id == me) or nil
    end
  end
  guihooks.trigger('RaceManagerDrag', data)
end

-- This driver has a lane in the pass being staged. Placement goes through the
-- same queue the racing grid and the derby form-up use: ghosted, staggered by
-- lane number, collisions back once the field has landed. Eight cars teleported
-- onto adjacent slots on one tick is how a placement gets refused or lands two
-- cars inside each other.
D.onDragLane = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  S.lane  = tonumber(data.lane)
  S.dial  = tonumber(data.dial)
  S.delay = tonumber(data.delay) or 0
  S.reported = false
  S.foul = false
  -- A NEW PASS ON THE LINE: last time's numbers are done. This used to null
  -- the three fields and tell nobody, so the panel went on showing them until
  -- a fresh result happened to replace them.
  clearSlip()
  S.rollup = data.rollup == true
  S.preStaged, S.inBeams = not S.rollup, not S.rollup
  S.line = nil
  local slot = tonumber(data.slot)
  if not slot then
    if data.hold == true then host.requestHold('drag') end
    return
  end
  -- CALLED, not read: the host reassigns this table when a layout loads, so a
  -- value captured at init would be the empty one the mod started with.
  local slots = host.startPositions()
  local sp = slots[slot]
  local count = math.max(tonumber(data.count) or slot, slot)
  if S.rollup and sp then
    -- The beams are measured against the start position itself, and the car
    -- is put down a few metres SHORT of it so there is something to roll up.
    S.line    = { x = sp.x, y = sp.y, hx = sp.hx or 0, hy = sp.hy or 1 }
    S.preAt   = tonumber(data.prestageAt) or S.preAt
    S.stageAt = tonumber(data.stageAt) or S.stageAt
    S.pastAt  = tonumber(data.stagePast) or S.pastAt
    local back = tonumber(data.back) or 5.0
    -- A ONE-SLOT LIST, so the shared placement queue stands the car where this
    -- module wants it without the host learning what a drag strip is. The
    -- stagger still runs on the real lane number, which is what `order` is
    -- for -- eight cars landing on the same tick is how a placement gets
    -- refused or two of them end up inside each other.
    host.queueFieldPlacement({
      slot  = 1,
      slots = { { x = sp.x - (sp.hx or 0) * back, y = sp.y - (sp.hy or 1) * back,
                  z = sp.z, hx = sp.hx, hy = sp.hy } },
      hold  = false,
      holdSource = 'drag',
      order = slot, count = count,
    })
    host.pushNotice('drag', 'Roll up into the beams: creep forward until both '
      .. 'blue lights are on.')
  else
    host.queueFieldPlacement({
      slot  = slot,
      slots = slots,
      hold  = data.hold == true,
      holdSource = 'drag',
      order = slot,
      count = count,
    })
  end
  pushTree('staged', true)
end

-- The tree. THE HOLD COMES OFF HERE, at the first light and not at the green,
-- and that is what makes a red light possible at all: a staged driver is free
-- to go whenever they like, and going early is a foul rather than something the
-- game prevents. A car frozen until the green cannot foul, which would quietly
-- delete half of what a drag race is.
D.onDragTree = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local preroll = tonumber(data.preroll) or 1.5
  S.pattern  = data.pattern == 'pro' and 'pro' or 'sportsman'
  S.delay    = tonumber(data.delay) or 0
  S.dial     = tonumber(data.dial)
  S.lane     = tonumber(data.lane) or S.lane
  S.t        = 0
  S.treeAt   = preroll + S.delay
  S.greenAt  = S.treeAt + lightsFor(S.pattern)
  S.timeoutAt = S.greenAt + (tonumber(data.timeout) or 60)
  S.launchAt, S.foul, S.reported = nil, false, false
  -- UNDER ROLL-UP THERE IS NO HOLD TO COME OFF: the car has been free the
  -- whole time it was creeping. releaseForLaunch still runs, because the
  -- other half of its job -- anchoring the launch where the car is standing
  -- when its own lights start -- is exactly right either way, and under
  -- roll-up that anchor IS the stage beam.
  S.released = false
  S.running  = true
  S.watching = false
  -- NO ANCHOR AND NO RELEASE YET under 'hold': both wait for this driver's own
  -- first light -- see releaseForLaunch for why taking them here was wrong
  -- twice over. Until then the car is frozen on its lane, which is where a
  -- held car belongs.
  --
  -- UNDER ROLL-UP THE ANCHOR ALREADY EXISTS and is kept: it is the stage beam
  -- the driver rolled into, and it is what makes a pre-roll departure a red
  -- light rather than an untimed one.
  if not S.rollup then S.anchor = nil end
  S.prevPos = nil
  pushTree('staged')
end

-- The same lights for everybody who is not in the pass.
D.onDragTreeWatch = function (rawData)
  if S.running then return end     -- a driver in the pass has their own tree
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local preroll = tonumber(data.preroll) or 1.5
  S.pattern  = data.pattern == 'pro' and 'pro' or 'sportsman'
  S.t        = 0
  S.treeAt   = preroll
  S.greenAt  = preroll + lightsFor(S.pattern)
  S.watching = true
  pushTree('staged')
end

D.onDragAborted = function (rawData)
  host.releaseGridHold('drag')
  S.watching = false
  S.reported = true          -- nothing to report: the pass never counted
  S.lane, S.delay = nil, 0
  endRun('off')
  clearSlip()
end

-- ===========================================================================
-- UI -> server
-- ===========================================================================
-- Thin relays, all of them. The server is the authority on every one of these
-- and re-checks the admin password on arrival; a disabled button has never
-- stopped anybody who can reach the console.
local function send(event, payload)
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Drag racing needs a BeamMP server' })
    return
  end
  TriggerServerEvent(event, payload or '')
end

function D.dragRequestState()
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DragRequestState', '')
  else
    guihooks.trigger('RaceManagerDrag', {
      dragPhase = 'idle', format = 'single', lanes = 2, advance = 1,
      tree = 'sportsman', seed = 'random', dialIn = false, breakout = true,
      stripLanes = 0, stripGates = 0, entrants = {}, board = {},
    })
  end
end

-- POSITIONAL, not a JSON string, because the UI reaches this through
-- bngApi.engineLua and that is a string of Lua being built by hand. Every other
-- admin control in this mod is spelled the same way for the same reason: a JSON
-- payload assembled inside a Lua expression inside a JavaScript string is three
-- quoting rules deep, and one of them always loses.
function D.dragSetConfig(format, lanes, advance, cut, rounds, tree, seed,
                         dialIn, breakout, timeout)
  send('RM_DragSetConfig', jsonEncode({
    format = format, lanes = tonumber(lanes), advance = tonumber(advance),
    cut = tonumber(cut), rounds = tonumber(rounds),
    tree = tree, seed = seed,
    dialIn = dialIn == true or dialIn == 1,
    breakout = breakout == true or breakout == 1,
    timeout = tonumber(timeout),
  }))
end
-- THE START PROCEDURE, on a call of its own rather than three more arguments
-- on dragSetConfig. That one is already ten positional parameters deep, which
-- is as far as a hand-built engineLua string should be asked to go before a
-- misplaced comma starts silently setting the wrong rule.
function D.dragSetStaging(mode, autoStart, wait)
  send('RM_DragSetConfig', jsonEncode({
    stageMode = mode,
    autoStart = autoStart == true or autoStart == 1,
    stageWait = tonumber(wait),
  }))
end
function D.dragBuild()           send('RM_DragBuild', '') end
function D.dragClear()           send('RM_DragClear') end
function D.dragStage()           send('RM_DragStage') end
-- One pass down the strip that scores nothing. Stages and holds in the same
-- press, because a warm-up should not need the ceremony a tournament round does.
function D.dragPractice()        send('RM_DragPractice') end
function D.dragRun()             send('RM_DragRun') end
function D.dragAbort()           send('RM_DragAbort') end
function D.dragWithdraw(seed)
  send('RM_DragWithdraw', '{"seed":' .. (tonumber(seed) or 0) .. '}')
end

-- A driver declaring their own dial-in, or an admin setting one for somebody
-- else. One event either way; the server tells them apart by whether a seed
-- came with it, and refuses the seed form from a non-admin.
function D.dragSetDial(dial, seed)
  local d = tonumber(dial)
  local parts = { '"dial":' .. (d and string.format('%.3f', d) or 'null') }
  if seed then parts[#parts + 1] = '"seed":' .. tonumber(seed) end
  send('RM_DragSetDial', '{' .. table.concat(parts, ',') .. '}')
end

-- ===========================================================================
-- End of DRAG RACING module
-- ===========================================================================

return D
