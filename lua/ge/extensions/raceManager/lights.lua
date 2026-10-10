-- Race Manager: THE LIGHTS, client side.
--
-- One light for the Race Lights (PRM) app, decided here from the session, the
-- countdown, this driver's own flag edges and the drag tree, and pushed on
-- RaceManagerLights only when it changes: a handful of times a race, never per
-- frame. The app draws what it is told and binds nothing, so it adds nothing to
-- the digest the main panel already pays for.
--
-- The SOUNDS play from here, on the same transitions, so a driver hears them
-- whether or not the Lights app is on screen.

local D = { soundOn = true }
local host

-- What was last pushed, the countdown number showing (3..1), and the drag
-- tree's payload while it is lit.
local lightShown = 'off'
local countdownNum = nil
local treeLit = nil

-- The game's own race beeps, as BeamJoy plays them.
local SOUND = {
  beep = 'event:UI_Countdown1',
  go   = 'event:UI_CountdownGo',
  stop = 'event:>UI>Main>Cancel',
}

-- Seconds a moment holds before the app falls back to the standing light. The
-- app keeps the time, so nothing here runs on a clock.
local HOLD = { go = 3, green = 4, white = 4, checkered = 6, blue = 4 }

-- The standing lights a race is HELD under. Leaving one for plain racing is the
-- green flag, whichever way it happened: pace lap, restart, red lifted.
local HELD = {
  pace = true, ready = true, restart = true, caution = true,
  cautionBack = true, yellow = true, red = true,
}

function D.init(h)
  host = h
end

local function play(which)
  if not D.soundOn then return end
  local audio = Engine and Engine.Audio
  if audio and audio.playOnce then pcall(audio.playOnce, 'AudioGui', SOUND[which]) end
end

local function running()
  local p = host.session.phase
  return p == 'racing' or p == 'qualifying'
end

-- The standing light. ORDER IS PRIORITY: red stops everything, a countdown
-- beats the flags, and GET READY beats the caution or pace lap it is ending.
local function standing()
  local s = host.session
  if treeLit then return 'tree' end
  if running() and s.raceFlag == 'red' then return 'red' end
  if countdownNum then return 'count' .. countdownNum end
  if not running() then
    return (s.phase == 'grid' or s.phase == 'countdown') and 'grid' or 'off'
  end
  if s.greenReady and (s.pacing or s.restartPending) then return 'ready' end
  if s.restartPending then return 'restart' end
  if s.cautionPending then return 'cautionBack' end
  if s.caution then return 'caution' end
  if s.pacing then return 'pace' end
  if s.raceFlag == 'yellow' then return 'yellow' end
  return 'off'
end

local function push(moment)
  guihooks.trigger('RaceManagerLights', {
    light = lightShown, tree = treeLit, moment = moment,
    hold = moment and HOLD[moment] or nil,
  })
end

-- Work the light out again and push it if it moved. A moment always pushes.
local function settle(moment)
  local light = standing()
  local was = lightShown
  if light == was and not moment then return end
  lightShown = light
  if light ~= was then
    if light == 'ready' then
      play('beep')
    elseif light == 'red' then
      play('stop')
    elseif light == 'off' and HELD[was] and running() and not moment then
      moment = 'green'
      play('go')
    end
  end
  push(moment)
end

-- After every state broadcast.
function D.lightsSync()
  settle()
end

-- 3, 2, 1, then 0 for GO, or -1 for a countdown called off. `derby` is set
-- for the derby's countdown, which the race's pace-lap rule has nothing to do with.
function D.lightsCountdown(n, derby)
  n = tonumber(n)
  if n and n > 0 then
    countdownNum = math.floor(n)
    play('beep')
    settle()
    return
  end
  countdownNum = nil
  if n == 0 then
    -- A START BEHIND THE PACE CAR IS NOT A GREEN. The lights go out and the
    -- pace lap's yellow follows on the next broadcast; green here would tell
    -- the field to race the formation lap.
    if not derby and host.pacedStart() then
      play('beep')
      settle()
    else
      play('go')
      settle('go')
    end
    return
  end
  settle()
end

-- This driver's own flags: 'white', 'checkered', 'blue'.
function D.lightsMoment(kind)
  if HOLD[kind] then settle(kind) end
end

-- The drag tree, as drag.lua pushes it to the panel. The bulbs move inside one
-- standing light, so every change is pushed rather than only a new light.
function D.lightsTree(t)
  local stage = type(t) == 'table' and t.stage or 'off'
  local was = treeLit and treeLit.stage or 'off'
  treeLit = (stage ~= 'off') and t or nil
  if stage ~= was then
    if stage == 'amber1' or stage == 'amber2' or stage == 'amber3' then
      play('beep')
    elseif stage == 'green' then
      play('go')
    end
  end
  lightShown = standing()
  push()
end

-- The app asking for the light it missed (it loaded, or the UI reloaded).
-- Without the moment: one that is already over must not replay.
function D.lightsResend()
  push()
end

function D.lightsSetSound(on)
  D.soundOn = on ~= false
end

return D
