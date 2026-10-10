-- Phoenix Race Manager: THE WELCOME SPLASH, client side.
--
-- A racer who has never added the app cannot be told about it by the app, so
-- this is an imgui window drawn from GE Lua. Offered once per join, on the
-- first targeted state reply, so it only ever appears on a server running the
-- plugin. "Don't show this again" is kept in the user folder.

local D = {}

local FILE = 'settings/raceManager/splash.json'
-- Pre-filled in the game's app picker: the prefix all three app names share.
local SEARCH = 'PRM'
-- Seconds after the state reply, so the car has landed first.
local DELAY = 3

local welcome = {
  offered = false,     -- this join has had its chance
  open = false,
  wait = nil,          -- countdown to opening
  hidden = nil,        -- the saved flag, read once
  hidePtr = nil,       -- imgui checkbox
}

function D.init() end

local function savedHidden()
  if welcome.hidden == nil then
    local ok, data = pcall(jsonReadFile, FILE)
    welcome.hidden = ok and type(data) == 'table' and data.hide == true
  end
  return welcome.hidden
end

local function close()
  welcome.open, welcome.wait = false, nil
  if welcome.hidePtr and welcome.hidePtr[0] then
    welcome.hidden = true
    if not pcall(jsonWriteFile, FILE, { hide = true }, true) then
      log('W', 'raceManager', 'Splash: could not save ' .. FILE)
    end
  end
end

-- Every targeted state reply lands here; only the first of a join counts.
function D.splashOffer()
  if welcome.offered then return end
  welcome.offered = true
  if not savedHidden() then welcome.wait = DELAY end
end

-- Leaving a server: the next join gets its own offer.
function D.splashReset()
  welcome.offered, welcome.open, welcome.wait = false, false, nil
end

-- Console: raceManager.splashShow() reopens it, saved flag or not.
function D.splashShow()
  welcome.offered, welcome.wait, welcome.open = true, nil, true
end

-- The HUD Apps screen, with the picker's search pre-filled. The picker reads the
-- search from Lua when it mounts. Both steps guarded: the routes are 0.39's.
local function openHudApps()
  pcall(function ()
    if not extensions.isExtensionLoaded('ui_appSelector_general') then
      extensions.load('ui_appSelector_general')
    end
    ui_appSelector_general.setSearchText(SEARCH)
  end)
  -- What the game's own "Edit UI apps" key sends.
  guihooks.trigger('MenuOpenModule', 'appedit')
end

local GOLD  = { 1.00, 0.62, 0.16, 1 }
local MUTED = { 0.72, 0.72, 0.72, 1 }

local function colored(im, c, text)
  im.TextColored(im.ImVec4(c[1], c[2], c[3], c[4]), text)
end

local function bullet(im, name, what)
  im.Bullet()
  im.SameLine()
  colored(im, GOLD, name)
  im.SameLine()
  im.TextWrapped(what)
end

local function body(im)
  colored(im, GOLD, 'This server runs Phoenix Race Manager.')
  im.TextWrapped('Qualifying, grids, race control, live timing and results all run '
    .. 'from its HUD apps. Add them to your screen to join in:')
  im.Spacing()
  bullet(im, 'PRM - Main', '(required) timing, race entry and results.')
  bullet(im, 'PRM - Race Lights', '(optional) start lights, flags and the drag tree.')
  bullet(im, 'PRM - Radar', '(optional) the cars around you and how close they are.')
  im.Spacing()
  colored(im, MUTED, 'HUD Apps > Edit layout > Add app. The search is filled in for you.')
  -- The same for every server: every racer reads this, so it must not say
  -- whether this one still has the default password, let alone print it.
  im.Spacing()
  im.Separator()
  colored(im, GOLD, 'Running this server?')
  im.TextWrapped('Log in from PRM - Main. The default admin password is in the README: '
    .. 'change it in the Admin password bar before your first public session.')
  im.Spacing()
  im.Separator()
  im.Checkbox("Don't show this again", welcome.hidePtr)
  if im.Button('Open HUD Apps', im.ImVec2(200, 0)) then
    close()
    openHudApps()
  end
  im.SameLine()
  if im.Button('Dismiss', im.ImVec2(-1, 0)) then close() end
end

-- Auto-height and no scrolling, so Dismiss is always on screen.
local function draw(im)
  local vp = im.GetMainViewport()
  im.SetNextWindowPos(im.ImVec2(vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2),
    im.Cond_Appearing, im.ImVec2(0.5, 0.5))
  im.SetNextWindowSize(im.ImVec2(460, 0), im.Cond_Always)
  if not welcome.hidePtr then welcome.hidePtr = im.BoolPtr(false) end
  local openPtr = im.BoolPtr(true)
  local flags = im.WindowFlags_NoCollapse + im.WindowFlags_NoResize
    + im.WindowFlags_NoSavedSettings + (im.WindowFlags_NoDocking or 0)
  local ok, err = true, nil
  if im.Begin('Phoenix Race Manager (PRM)##rmSplash', openPtr, flags) then
    -- End must run whatever the body does, or imgui's stack is left open.
    ok, err = pcall(body, im)
  end
  im.End()
  if not openPtr[0] then close() end
  if not ok then error(err, 0) end
end

function D.splashUpdate(dt)
  if welcome.wait then
    welcome.wait = welcome.wait - dt
    if welcome.wait > 0 then return end
    welcome.wait, welcome.open = nil, true
  end
  if not welcome.open then return end
  local im = ui_imgui
  if type(im) ~= 'table' then welcome.open = false; return end
  local ok, err = pcall(draw, im)
  if not ok then
    welcome.open = false
    log('E', 'raceManager', 'Splash draw failed: ' .. tostring(err))
  end
end

return D
