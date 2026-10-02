-- Race Manager: LAP RECORDS, the client half.
--
-- The boards live on the server (server/RaceManager/records.lua), which scores
-- them at the end of each session and owns the files. This file only carries
-- the panel's requests up and the answer down.

local D = {}
local host

function D.init(h)
  host = h
end

-- Anyone may look. layout nil asks for the loaded layout's board.
function D.recordsRequest(layout)
  if not host.inMultiplayer() then return end
  local data = {}
  if type(layout) == 'string' and layout ~= '' then data.layout = layout end
  TriggerServerEvent('RM_RecordsRequest', jsonEncode(data))
end

-- Admin tier only; the server checks.
function D.recordsClear(layout)
  if type(layout) ~= 'string' or layout == '' or not host.inMultiplayer() then return end
  TriggerServerEvent('RM_RecordsClear', jsonEncode({ layout = layout }))
end

function D.recordsRemove(layout, driver)
  if type(layout) ~= 'string' or layout == '' or type(driver) ~= 'string'
      or driver == '' or not host.inMultiplayer() then return end
  TriggerServerEvent('RM_RecordsRemove', jsonEncode({ layout = layout, driver = driver }))
end

function D.onRecords(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  guihooks.trigger('RaceManagerRecords', data)
end

return D
