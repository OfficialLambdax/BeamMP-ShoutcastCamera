package.loaded["libs/TriggerClientEvent"] = nil
local TriggerClientEvent = require("libs/TriggerClientEvent")


local ADMINS = {"beamcruisebot", "Neverless"}


function shoutoutBroadcast(player_id, server_vehicle_id)
	local player_name = MP.GetPlayerName(player_id)
	if not ADMINS[player_name] then return end
	
	print('Received shoutout from: "' .. player_name .. '" for ' .. server_vehicle_id)
	
	TriggerClientEvent:broadcastExcept(player_id, "shoutoutReceive", server_vehicle_id)
	--TriggerClientEvent:send(-1, "shoutoutReceive", server_vehicle_id)
end

function onPlayerJoin(player_id)
	TriggerClientEvent:set_synced(player_id)
end

function onPlayerDisconnect(player_id)
	TriggerClientEvent:remove(player_id)
end

function onInit()
	local admins = {}
	for _, admin in ipairs(ADMINS) do
		admins[admin] = true
	end
	ADMINS = admins
	
	MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
	MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
	
	MP.RegisterEvent("shoutoutBroadcast", "shoutoutBroadcast")
	
	for player_id, _ in pairs(MP.GetPlayers()) do
		onPlayerJoin(player_id)
	end
end
