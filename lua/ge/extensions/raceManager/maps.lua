-- Race Manager: MAP SWITCHING, the client half.
--
-- The switch and the vote happen on the server (server/RaceManager/maps.lua):
-- it counts the votes, moves the map zips, rewrites ServerConfig.toml and
-- restarts. This file only carries the panel's requests up and the answer down.

local D = {}
local host

function D.init(h)
  host = h
end

-- withList false asks for the state alone, which skips reading every map zip.
function D.mapRequest(withList)
  if not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapRequest', withList == false and '{"list":false}' or '')
end

function D.mapSwitch(name)
  if type(name) ~= 'string' or name == '' or not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapSwitch', jsonEncode({ map = name }))
end

function D.mapCancel()
  if not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapCancel', '')
end

-- Anyone may call a vote; the server decides whether voting is open to them.
function D.mapVoteStart(name)
  if type(name) ~= 'string' or name == '' or not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapVoteStart', jsonEncode({ map = name }))
end

function D.mapVote(yes)
  if not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapVote', jsonEncode({ yes = yes == true }))
end

function D.mapVoteCancel()
  if not host.inMultiplayer() then return end
  TriggerServerEvent('RM_MapVoteCancel', '')
end

-- Either argument may be nil to leave that setting alone.
function D.mapVoteConfig(enabled, percent)
  if not host.inMultiplayer() then return end
  local data = {}
  if type(enabled) == 'boolean' then data.enabled = enabled end
  if tonumber(percent) then data.percent = math.floor(tonumber(percent)) end
  TriggerServerEvent('RM_MapVoteConfig', jsonEncode(data))
end

function D.onMaps(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  guihooks.trigger('RaceManagerMaps', data)
end

return D
