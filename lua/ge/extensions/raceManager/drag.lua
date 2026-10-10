-- Race Manager: DRAG RACING, as its own module.
--
-- The client half of the ladder in server/RaceManager/drag.lua: the server owns
-- the bracket, this file does what only a client can.
--   * RUN THE CHRISTMAS TREE on this machine's clock: a reaction time timed
--     against a server tick would measure the network. The server sends the
--     tree's SHAPE (pattern, pre-roll, this lane's handicap).
--   * MEASURE THE PASS: reaction time, elapsed time, trap speed, and a foul.
-- THE HANDICAP IS THE WHOLE TREE: the quicker car's tree starts later by the
-- dial-in difference, so each driver launches on their own green.
-- THE CONTRACT is the derby's (functions, getters, tables by reference). The
-- route and start positions come through GETTERS: they are REASSIGNED when a
-- layout loads (tests/wiring_test.lua checks this).

local D = {}
local host

function D.init(h)
  host = h
end

-- ===========================================================================
-- Tunables
-- ===========================================================================
-- Distance off the staged position that counts as a launch: past settle,
-- shunts and release jiggle, short enough to stamp the real moment.
local DRAG_LAUNCH_DIST = 0.5
-- Three ambers together, green four tenths later. The professional tree.
local DRAG_PRO_LIGHTS  = 0.4
-- Sportsman tree: ambers half a second apart, green after the last.
local DRAG_SPORT_STEP  = 0.5
local DRAG_SPORT_LIGHTS = DRAG_SPORT_STEP * 3
local MPS_TO_MPH = 2.236936
-- How long the time slip stays up: a RESULT, not a state (it once lingered over
-- other tabs for twenty minutes). clearSlip handles the known paths; this is
-- the backstop.
local DRAG_SLIP_SECONDS = 25

-- One table, for the locals ceiling.
D.dragState = {
  phase   = 'idle',     -- mirrored from the server
  lane    = nil,        -- which lane this driver is in, or nil for a spectator
  dial    = nil,
  delay   = 0,          -- this lane's handicap, in seconds
  -- The run in progress, measured locally and reset for every pass.
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
  -- ROLL-UP: the car is placed BEHIND the line, free, and creeps forward until
  -- the bulbs light. The beam thresholds arrive from the server with `line`.
  rollup    = false,
  line      = nil,      -- { x, y, hx, hy } the beams are measured from
  preAt     = -1.2,
  stageAt   = -0.35,
  pastAt    = 2.0,
  preStaged = false,
  inBeams   = false,
  -- The last pass, for the HUD, and the seconds it has left.
  lastRT = nil, lastET = nil, lastSpeed = nil,
  slipLeft = 0,
  -- A spectator's copy of the tree.
  watching = false,
}

local S = D.dragState

local function lightsFor(pattern)
  return pattern == 'pro' and DRAG_PRO_LIGHTS or DRAG_SPORT_LIGHTS
end

-- Staging steps in the game's Messages app; one category, so each replaces the
-- last.
local function stageHint(text)
  if host.hudMessage then host.hudMessage('stage', text) end
end

-- The lights. The stage bulbs are sent apart from the ambers: under roll-up
-- they say where the car is, not a moment in a countdown.
local function pushTree(stage, force)
  if S.stage == stage and not force then return end
  S.stage = stage
  local t = {
    stage = stage, lane = S.lane, dial = S.dial, delay = S.delay,
    prestaged = S.preStaged, staged = S.inBeams, rollup = S.rollup,
  }
  guihooks.trigger('RaceManagerDragTree', t)
  if host.lightsTree then host.lightsTree(t) end
end

-- Wind the local run down, from every path that ends one.
local function endRun(stage)
  S.running  = false
  S.released = false
  S.rollup, S.line = false, nil
  S.preStaged, S.inBeams = false, false
  S.treeAt, S.greenAt, S.timeoutAt = nil, nil, nil
  S.anchor, S.prevPos, S.launchAt = nil, nil, nil
  pushTree(stage or 'off')
end

-- THE HOLD COMES OFF AT THIS DRIVER'S FIRST LIGHT, and the launch anchor is
-- taken then, not when Run is pressed: the car may still be landing (placement
-- is staggered 0.18 s a lane), and a mid-flight anchor reads as a launch. The
-- 1.5 s pre-roll floor outlasts the widest field; if a placement is still
-- running the release waits a frame, never past the green.
local function releaseForLaunch()
  if S.released then return end
  local landing = host.placementActive and host.placementActive()
  if landing and S.t < (S.greenAt or 0) then return end
  local _, pos = host.sampledVehicle()
  S.released = true
  -- Under roll-up the anchor is already the stage beam; only take one if none.
  if not S.anchor then
    S.anchor = pos and { x = pos.x, y = pos.y, z = pos.z } or nil
  end
  S.prevPos = S.prevPos or pos
  host.releaseGridHold('drag')
end

-- Take the time slip down, on the panel too.
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
  -- The driver's own numbers, on their own screen, at once.
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

-- Signed distance from the beams along the line's heading (negative short,
-- positive past). Projected, so a car to one side of its lane is still staged.
local function beamDistance(pos)
  if not (S.line and pos) then return nil end
  local dx, dy = pos.x - S.line.x, pos.y - S.line.y
  return dx * (S.line.hx or 0) + dy * (S.line.hy or 1)
end

-- Creeping into the beams, under roll-up, before the tree. Once it runs the
-- bulbs freeze: leaving them then is a launch.
local function stagingUpdate()
  if not (S.rollup and S.line) or S.running then return end
  local _, pos = host.sampledVehicle()
  local d = beamDistance(pos)
  if not d then return end
  local pre = d >= S.preAt and d <= S.pastAt
  local inb = d >= S.stageAt and d <= S.pastAt
  -- The launch is measured from the stage beam, so the anchor is taken here and
  -- kept current while the car sits in the beams (staging deep is deliberate);
  -- frozen once the tree starts. Taken at the first amber, a roll-up car that
  -- left during the pre-roll was never fouled.
  if inb and pos then S.anchor = { x = pos.x, y = pos.y, z = pos.z } end
  if pre == S.preStaged and inb == S.inBeams then return end
  S.preStaged, S.inBeams = pre, inb
  if inb then
    stageHint('STAGED: stop and wait. Go when the light turns GREEN; leaving early is a red light.')
  elseif pre then
    stageHint('PRE-STAGED: inch forward until the STAGE light comes on too.')
  elseif d > S.pastAt then
    stageHint('TOO FAR: back up until the STAGE light comes back on.')
  else
    stageHint('ROLL UP: creep forward slowly until the PRE-STAGE light comes on.')
  end
  -- On change only.
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
-- Does nothing unless this client is in the pass; a spectator runs the tree.
function D.dragUpdate(dt)
  -- Before every early return: the slip must expire regardless.
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

  -- The lights, on this driver's own tree, NOT once fouled: a red light stays
  -- red for the rest of the run.
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

  -- LAUNCH: distance off the staged position, not speed (a sideways shunt is
  -- not a launch, a crawl forward is).
  if not S.launchAt and S.anchor then
    local dx, dy = pos.x - S.anchor.x, pos.y - S.anchor.y
    if (dx * dx + dy * dy) >= (DRAG_LAUNCH_DIST * DRAG_LAUNCH_DIST) then
      S.launchAt = S.t
      -- A red light is a FOUL, not a cancelled pass: the server decides its cost.
      if S.t < (S.greenAt or 0) then
        S.foul = true
        pushTree('red')
        host.pushNotice('drag', 'RED LIGHT - you left before the green.')
        stageHint('RED LIGHT: you left before the green. Next time, wait for GREEN.')
      end
    end
  end

  -- The finish is the loaded layout's last gate (a sprint stage is a strip).
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

  -- Gave up: report now rather than wait out the server's timeout.
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
  -- A pass no longer running releases every car it held, broadcast order aside.
  if newPhase ~= 'staging' and newPhase ~= 'tree' and newPhase ~= 'running' then
    -- Not gated on S.running: a red light ends the run when reported, and the
    -- bulb has to come off when the pass settles.
    if S.running or S.watching or S.stage ~= 'off' then
      S.watching = false
      endRun('off')
    end
    if S.phase == 'staging' or S.phase == 'tree' or S.phase == 'running' then
      host.releaseGridHold('drag')
      S.lane, S.delay = nil, 0
    end
    -- The ladder is gone (Clear Ladder, or after a practice pass): so is the slip.
    if newPhase == 'idle' then clearSlip() end
  end
  S.phase = newPhase
  -- Mark our own row: the board is one broadcast to everybody.
  local me = host.localServerId()
  if me and type(data.entrants) == 'table' then
    for _, row in ipairs(data.entrants) do
      row.you = (row.id ~= nil and row.id == me) or nil
    end
  end
  -- ...and our lane, for the Ready button; the HUD says when we are first called.
  local wasReady = S.myReady
  S.myReady = nil
  if me and type(data.current) == 'table' and type(data.current.lanes) == 'table' then
    for _, ln in ipairs(data.current.lanes) do
      if ln.id ~= nil and ln.id == me then
        ln.you = true
        if newPhase == 'staging' then S.myReady = ln.ready end
      end
    end
  end
  if S.myReady == false and wasReady == nil then
    host.pushNotice('drag', 'Your drag pass is up',
      { sub = 'Press READY in PRM - Main to put your car on the strip' })
  end
  guihooks.trigger('RaceManagerDrag', data)
end

-- This driver has a lane: placed through the shared queue, ghosted and
-- staggered by lane number.
D.onDragLane = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- Not ready any more: off the strip, hold released.
  if data.release == true then
    host.releaseGridHold('drag')
    S.lane, S.delay = nil, 0
    endRun('off')
    return
  end
  S.lane  = tonumber(data.lane)
  S.dial  = tonumber(data.dial)
  S.delay = tonumber(data.delay) or 0
  S.reported = false
  S.foul = false
  -- A new pass: last time's numbers are done.
  clearSlip()
  S.rollup = data.rollup == true
  S.preStaged, S.inBeams = not S.rollup, not S.rollup
  S.line = nil
  local slot = tonumber(data.slot)
  if not slot then
    if data.hold == true then host.requestHold('drag') end
    return
  end
  -- Called, not read: the host reassigns this table.
  local slots = host.startPositions()
  local sp = slots[slot]
  local count = math.max(tonumber(data.count) or slot, slot)
  if S.rollup and sp then
    -- The beams are at the start position; the car goes down short of it.
    S.line    = { x = sp.x, y = sp.y, hx = sp.hx or 0, hy = sp.hy or 1 }
    S.preAt   = tonumber(data.prestageAt) or S.preAt
    S.stageAt = tonumber(data.stageAt) or S.stageAt
    S.pastAt  = tonumber(data.stagePast) or S.pastAt
    local back = tonumber(data.back) or 5.0
    -- A one-slot list, so the shared queue needs no idea of a drag strip; the
    -- stagger still runs on the real lane number.
    host.queueFieldPlacement({
      slot  = 1,
      slots = { { x = sp.x - (sp.hx or 0) * back, y = sp.y - (sp.hy or 1) * back,
                  z = sp.z, hx = sp.hx, hy = sp.hy } },
      hold  = false,
      holdSource = 'drag',
      order = tonumber(data.order) or slot, count = count,
    })
    host.pushNotice('drag', 'Roll up into the beams: creep forward until PRE and '
      .. 'STAGE are both lit.')
    stageHint('ROLL UP: creep forward slowly until the PRE-STAGE light comes on.')
  else
    -- Placed on the line and held: already staged.
    stageHint('STAGED: you are held on the line. Go when the light turns GREEN; '
      .. 'leaving early is a red light.')
    host.queueFieldPlacement({
      slot  = slot,
      slots = slots,
      hold  = data.hold == true,
      holdSource = 'drag',
      order = tonumber(data.order) or slot,
      count = count,
    })
  end
  pushTree('staged', true)
end

-- The tree. The hold comes off at the first light, not the green, so leaving
-- early is a foul rather than something the game prevents.
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
  -- Under roll-up there is no hold, but releaseForLaunch still anchors.
  S.released = false
  S.running  = true
  S.watching = false
  -- Under 'hold', anchor and release wait for this driver's first light. Under
  -- roll-up the anchor (the stage beam) is kept.
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
-- Thin relays; the server re-checks the admin password on each.
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

-- Positional, not a JSON string: the UI builds this call as Lua source inside a
-- JavaScript string.
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
-- The start procedure, on its own call: dragSetConfig is ten positional
-- arguments deep already.
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
-- One unscored pass, staged and held in one press.
function D.dragPractice()        send('RM_DragPractice') end
function D.dragRun()             send('RM_DragRun') end
-- Ready check, refused with no car.
function D.dragReady(on)
  if on ~= false and not host.ownVehicle() then
    host.pushNotice('drag', 'Get in a car first', { sub = 'Then press Ready' })
    return
  end
  send('RM_DragReady', jsonEncode({ ready = on ~= false }))
end
-- Admin: ready one lane driver whose panel is closed, or every lane.
function D.dragReadyDriver(pid)
  pid = tonumber(pid)
  if pid then send('RM_DragReady', jsonEncode({ ready = true, pid = pid })) end
end
function D.dragReadyAll()        send('RM_DragReadyAll') end
function D.dragAbort()           send('RM_DragAbort') end
function D.dragWithdraw(seed)
  send('RM_DragWithdraw', '{"seed":' .. (tonumber(seed) or 0) .. '}')
end

-- A driver's own dial-in, or an admin's for a seed (refused from a non-admin).
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
