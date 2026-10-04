-- Race Manager: THE RADAR, client side.
--
-- The cars within range of this driver's own car, in that car's frame (x to the
-- right, y forward, meters), pushed on RaceManagerRadar while any are in range
-- and once more as the last one leaves. Alone, nothing is sent at all, and the
-- scan itself slows down.
--
-- Each car carries its gap: the distance between the two cars' outlines on the
-- ground, not between their centers. Alongside, that is the number a driver
-- wants, and center to center it reads two meters too far.

local D = {}
local host

local RANGE      = 25      -- meters to the other car's center; the app fades past it
local EDGE       = 6       -- scanned beyond RANGE so a car fades in rather than pops
local NEAR_EVERY = 0.05    -- seconds between pushes while a car is in range
local IDLE_EVERY = 0.25    -- between scans while nobody is
local OWNERS_EVERY = 2     -- seconds between refreshes of the vehicle-to-player map
local LEN, WID   = 4.5, 1.9  -- a car's size when the engine will not say

local wait = 0
local clock = 0
local sentCars = false
local dims = {}                         -- [vehId] = { model, hl, hw }
local owners = { at = -1, map = {} }    -- [gameVehId] = BeamMP player id
local rowsSeen, rowByPid = nil, {}
-- Scratch corners for the gap, reused so a scan allocates no tables for it.
local ca, cb = {}, {}

function D.init(h)
  host = h
end

local function call(fn)
  local ok, a, b, c = pcall(fn)
  if ok then return a, b, c end
end

-- A car's half length and half width, once per car and model: a car swapped
-- for another model keeps its id.
local function halfSize(veh, id)
  local model = call(function () return tostring(veh:getJBeamFilename()) end) or ''
  local d = dims[id]
  if d and d.model == model then return d.hl, d.hw end
  local l = call(function () return veh:getInitialLength() end)
  local w = call(function () return veh:getInitialWidth() end)
  l = (type(l) == 'number' and l > 0.5) and l or LEN
  w = (type(w) == 'number' and w > 0.5) and w or WID
  dims[id] = { model = model, hl = l * 0.5, hw = w * 0.5 }
  return l * 0.5, w * 0.5
end

-- Where a car is: the middle of its box where the engine gives one, which for
-- most cars is a meter or more behind the position the engine reports.
local function center(veh)
  local x, y = call(function () return veh:getSpawnWorldOOBBCenterXYZ() end)
  if type(x) == 'number' then return x, y end
  local p = call(function () return veh:getPosition() end)
  if p then return p.x, p.y end
end

local function heading(veh)
  local d = call(function () return veh:getDirectionVector() end)
  if not d then return nil end
  local n = math.sqrt(d.x * d.x + d.y * d.y)
  if n < 1e-6 then return nil end
  return d.x / n, d.y / n
end

-- The four corners of a rectangle in the radar's frame. (sx, sy) is the unit
-- vector it faces; its right is (sy, -sx).
local function corners(out, cx, cy, sx, sy, hl, hw)
  local rx, ry = sy, -sx
  out[1], out[2] = cx + sx * hl + rx * hw, cy + sy * hl + ry * hw
  out[3], out[4] = cx + sx * hl - rx * hw, cy + sy * hl - ry * hw
  out[5], out[6] = cx - sx * hl - rx * hw, cy - sy * hl - ry * hw
  out[7], out[8] = cx - sx * hl + rx * hw, cy - sy * hl + ry * hw
end

-- Do the projections of two quads onto (ax, ay) overlap?
local function overlapOn(ax, ay)
  local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
  for i = 1, 7, 2 do
    local p = ca[i] * ax + ca[i + 1] * ay
    if p < amin then amin = p end
    if p > amax then amax = p end
    local q = cb[i] * ax + cb[i + 1] * ay
    if q < bmin then bmin = q end
    if q > bmax then bmax = q end
  end
  return amax >= bmin and bmax >= amin
end

local function pointSegment(px, py, x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  local len2 = dx * dx + dy * dy
  local t = len2 > 0 and ((px - x1) * dx + (py - y1) * dy) / len2 or 0
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local ex, ey = x1 + dx * t - px, y1 + dy * t - py
  return ex * ex + ey * ey
end

-- Shortest squared distance from any corner of p to any edge of q.
local function cornersToEdges(p, q, best)
  for i = 1, 7, 2 do
    for j = 1, 7, 2 do
      local k = j + 2 > 7 and 1 or j + 2
      local d = pointSegment(p[i], p[i + 1], q[j], q[j + 1], q[k], q[k + 1])
      if d < best then best = d end
    end
  end
  return best
end

-- The gap between quads ca and cb: 0 when they touch, else the shortest
-- distance between their outlines. Two convex shapes that do not touch are
-- closest at a corner of one against an edge of the other.
local function gap()
  if overlapOn(ca[3] - ca[1], ca[4] - ca[2]) and overlapOn(ca[7] - ca[1], ca[8] - ca[2])
      and overlapOn(cb[3] - cb[1], cb[4] - cb[2]) and overlapOn(cb[7] - cb[1], cb[8] - cb[2]) then
    return 0
  end
  return math.sqrt(cornersToEdges(cb, ca, cornersToEdges(ca, cb, math.huge)))
end

-- Which BeamMP player drives each car, refreshed now and then rather than per
-- scan: the list only changes when a car is spawned or removed.
local function ownerOf(id)
  if clock - owners.at >= OWNERS_EVERY or (owners.map[id] == nil and clock - owners.at >= 1) then
    owners.at = clock
    owners.map = {}
    if MPVehicleGE and type(MPVehicleGE.getVehicles) == 'function' then
      local list = call(MPVehicleGE.getVehicles)
      if type(list) == 'table' then
        for _, v in pairs(list) do
          if type(v) == 'table' and v.gameVehicleID ~= nil and v.ownerID ~= nil then
            owners.map[v.gameVehicleID] = tostring(v.ownerID)
          end
        end
      end
    end
  end
  return owners.map[id]
end

-- The server's row for a player, from the last state broadcast.
local function rowFor(pid)
  local rows = host.rows()
  if rows ~= rowsSeen then
    rowsSeen, rowByPid = rows, {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
      if type(r) == 'table' and r.id ~= nil then rowByPid[tostring(r.id)] = r end
    end
  end
  return pid and rowByPid[pid]
end

local function progress(r, slots)
  return (tonumber(r.currentLap) or 0) * slots + (tonumber(r.cpCleared) or 0)
end

local function round(v, n)
  local m = 10 ^ n
  return math.floor(v * m + 0.5) / m
end

local function scan()
  local cars = {}
  if host.quiet() then return cars, nil end
  local me = host.ownVehicle()
  if not me then return cars, nil end
  local myId = call(function () return me:getID() end)
  local mx, my = center(me)
  local fx, fy = heading(me)
  if not (myId and mx and fx) then return cars, nil end
  local rx, ry = fy, -fx
  local mhl, mhw = halfSize(me, myId)
  corners(ca, 0, 0, 0, 1, mhl, mhw)

  -- Positions and lap relations mean something only in a race. Qualifying's
  -- order is best laps, which is not who you are racing on the road.
  local racing = host.racing()
  local slots = racing and host.slots() or 0
  local mine = racing and slots > 0 and rowFor(tostring(host.myPid() or '')) or nil
  local reach2 = (RANGE + EDGE) * (RANGE + EDGE)

  host.forEachVehicle(myId, function (veh, id)
    if call(function () return veh:isHidden() end) then return end
    if call(function () return tostring(veh:getJBeamFilename()) end) == 'unicycle' then return end
    if host.isTowed(veh) then return end
    local cx, cy = center(veh)
    if not cx then return end
    local dx, dy = cx - mx, cy - my
    if dx * dx + dy * dy > reach2 then return end
    local hx, hy = heading(veh)
    if not hx then hx, hy = fx, fy end
    local x, y = dx * rx + dy * ry, dx * fx + dy * fy
    local sx, sy = hx * rx + hy * ry, hx * fx + hy * fy
    local hl, hw = halfSize(veh, id)
    corners(cb, x, y, sx, sy, hl, hw)
    local car = {
      x = round(x, 2), y = round(y, 2),
      a = round(math.deg(math.atan2(sx, sy)), 1),
      l = round(hl * 2, 2), w = round(hw * 2, 2),
      g = round(gap(), 2),
    }
    if host.isGhost(id) then car.gh = true end
    if racing then
      local r = rowFor(ownerOf(id))
      if r then
        car.p = tonumber(r.position)
        if mine and slots > 0 then
          local laps = math.floor((progress(r, slots) - progress(mine, slots)) / slots + 0.5)
          if laps ~= 0 then car.lap = laps end
        end
      end
    end
    cars[#cars + 1] = car
  end)
  return cars, { l = round(mhl * 2, 2), w = round(mhw * 2, 2) }
end

function D.radarUpdate(dt)
  clock = clock + dt
  wait = wait - dt
  if wait > 1e-6 then return end
  local cars, me = scan()
  local near = #cars > 0
  -- Added to what is left rather than reset, so the rate holds at any frame
  -- rate; never below zero, so a stall does not queue up a burst.
  wait = math.max(wait + (near and NEAR_EVERY or IDLE_EVERY), 0)
  -- One empty push as the last car leaves, so the app can fade; then silence.
  if not near and not sentCars then return end
  sentCars = near
  guihooks.trigger('RaceManagerRadar', { range = RANGE, edge = EDGE, me = me, cars = cars })
end

-- For tests: the gap between two rectangles given in one frame.
function D.radarGap(x1, y1, a1, l1, w1, x2, y2, a2, l2, w2)
  local r1, r2 = math.rad(a1), math.rad(a2)
  corners(ca, x1, y1, math.sin(r1), math.cos(r1), l1 * 0.5, w1 * 0.5)
  corners(cb, x2, y2, math.sin(r2), math.cos(r2), l2 * 0.5, w2 * 0.5)
  return gap()
end

return D
