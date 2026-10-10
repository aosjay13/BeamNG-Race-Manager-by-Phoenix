-- Headless test for THE WELCOME SPLASH in lua/ge/extensions/raceManager/splash.lua.
--
-- Pinned: it opens once per join after a delay, the saved flag keeps it shut,
-- Dismiss is always drawn, Open HUD Apps reaches the game's app screen with the
-- search filled in, and the admin line never prints or hints at the password.
--
-- Run from the repo root: lua5.3 tests/splash_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs: a recording imgui, the user folder, guihooks, the app selector
-- ---------------------------------------------------------------------------
local hooks, files, searchText, loaded = {}, {}, nil, {}
log = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
jsonReadFile  = function (p) return files[p] end
jsonWriteFile = function (p, t) files[p] = t; return true end
extensions = {
  isExtensionLoaded = function (n) return loaded[n] == true end,
  load = function (n) loaded[n] = true end,
}
ui_appSelector_general = { setSearchText = function (v) searchText = v end }

-- Each frame: the text drawn, the buttons drawn, and which to "click".
local frame, click, closeX, tick = nil, {}, false, nil
local function ptr(v) return { [0] = v } end
ui_imgui = {
  WindowFlags_NoCollapse = 1, WindowFlags_NoResize = 2, WindowFlags_NoSavedSettings = 4,
  Cond_Appearing = 1, Cond_Always = 2,
  ImVec2 = function (x, y) return { x = x, y = y } end,
  ImVec4 = function (...) return { ... } end,
  BoolPtr = ptr,
  GetMainViewport = function () return { Pos = { x = 0, y = 0 }, Size = { x = 1920, y = 1080 } } end,
  SetNextWindowPos = function () end, SetNextWindowSize = function () end,
  Begin = function (_, open)
    frame = { text = {}, buttons = {}, ended = false }
    if closeX then open[0] = false end
    return true
  end,
  End = function () frame.ended = true end,
  Text = function (t) frame.text[#frame.text + 1] = t end,
  TextWrapped = function (t) frame.text[#frame.text + 1] = t end,
  TextColored = function (_, t) frame.text[#frame.text + 1] = t end,
  Bullet = function () end, SameLine = function () end,
  Spacing = function () end, Separator = function () end,
  Checkbox = function (_, p) if tick ~= nil then p[0] = tick end; return false end,
  Button = function (label)
    frame.buttons[#frame.buttons + 1] = label
    return click[label] == true
  end,
}

local S = dofile('lua/ge/extensions/raceManager/splash.lua')

local function drew(needle)
  if not frame then return false end
  for _, t in ipairs(frame.text) do if t:find(needle, 1, true) then return true end end
  return false
end
local function hasButton(label)
  for _, b in ipairs(frame and frame.buttons or {}) do if b == label then return true end end
  return false
end
local function run(seconds)
  frame = nil
  local t = 0
  while t < seconds do S.splashUpdate(0.5); t = t + 0.5 end
end

-- ---------------------------------------------------------------------------
-- Opens after the delay, once per join
-- ---------------------------------------------------------------------------
S.splashOffer()
run(1)
check(frame == nil, 'nothing is drawn before the delay')
run(3)
check(frame ~= nil and frame.ended, 'opens after the delay, Begin paired with End')
check(drew('PRM - Main') and drew('PRM - Race Lights') and drew('PRM - Radar'), 'names all three apps')
check(not drew('phoenix'), 'the password is never printed')
check(hasButton('Dismiss') and hasButton('Open HUD Apps'), 'both buttons drawn')
check(drew('Running this server?') and drew('README'), 'the admin line points at the README')
check(not drew('still'), 'and never says whether this server still has the default')

-- ---------------------------------------------------------------------------
-- Dismiss closes, and does not save unless ticked
-- ---------------------------------------------------------------------------
click = { Dismiss = true }
run(1)
click = {}
run(1)
check(frame == nil, 'Dismiss closes it')
check(files['settings/raceManager/splash.json'] == nil, 'Dismiss alone saves nothing')
S.splashOffer()
run(5)
check(frame == nil, 'a second reply in the same join does not reopen it')

-- ---------------------------------------------------------------------------
-- The title-bar X closes it too
-- ---------------------------------------------------------------------------
S.splashReset()
S.splashOffer()
run(4)
check(frame ~= nil, 'a new join offers again')
closeX = true
run(1)
closeX = false
run(1)
check(frame == nil, 'the title-bar X closes it')

-- ---------------------------------------------------------------------------
-- Open HUD Apps: the game's app screen, search pre-filled, flag saved if ticked
-- ---------------------------------------------------------------------------
S.splashReset()
S.splashOffer()
run(4)
tick, click = true, { ['Open HUD Apps'] = true }
run(1)
tick, click = nil, {}
local opened = false
for _, h in ipairs(hooks) do
  if h.event == 'MenuOpenModule' and h.payload == 'appedit' then opened = true end
end
check(opened, 'Open HUD Apps sends MenuOpenModule appedit')
check(loaded.ui_appSelector_general, 'the app selector extension is loaded first')
check(searchText == 'PRM', 'the picker search is pre-filled')
check(files['settings/raceManager/splash.json'] and files['settings/raceManager/splash.json'].hide == true,
  "Don't show again is saved")
run(1)
check(frame == nil, 'closed after opening HUD Apps')

-- The saved flag keeps it shut on the next join, and the console still opens it.
S.splashReset()
S.splashOffer()
run(5)
check(frame == nil, 'the saved flag keeps it shut')
S.splashShow()
run(1)
check(frame ~= nil, 'splashShow opens it regardless')

-- A missing app selector (an older game) still opens HUD Apps.
ui_appSelector_general, hooks = nil, {}
loaded.ui_appSelector_general = true
click = { ['Open HUD Apps'] = true }
run(1)
click = {}
check(#hooks == 1 and hooks[1].payload == 'appedit', 'no selector: still opens HUD Apps')

-- A throw inside the window still ends it, and the splash shuts.
S.splashShow()
ui_imgui.Bullet = function () error('boom') end
run(1)
check(frame.ended, 'End runs after a throw in the body')
run(1)
check(frame == nil, 'shut after the throw')

print(string.format('splash_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
