local M = {}

--[[
	This is more of a playground then anything. Cameras should be coded in the their respective camera not in some ge extension.
	
	Todo
		- Sync player overwrite
		- Switching between prefabs
		- Camera Categorization to add variants such as aimed or fixed
]]

local DISTANCE_SWITCH_MIN = 80
local DISTANCE_SWITCH_MAX = 200
local IGNORE_FURTHER_THEN = 200 -- ignores cams this far away
local TIME_LIFE_MIN = 4000
local TIME_LOST_LOS_MIN = 300
local PRE_POS_TIME = 0.15
local DRAW_DEBUG = false
local DRAW_UI = true
local ACCEPT_SHOUTOUTS = true

--[[
	Format
		[1..n] = table
			[pos] = vec3
]]
local CAMERAS = {}
local C_CAMERA = nil
local C_FOV = 0

local ROOT_GROUP = "shoutcasting"
local CAM_NAME = "shoutcasting"
local INITIALIZED = false
local IS_RUNNING = false
local LOST_LOS = hptimer()
local CAM_LIFE_TIME = hptimer()
local AVG_LIFE_TIME = {}
local DISTANCE_SWITCH_NEXT = math.random(DISTANCE_SWITCH_MIN, DISTANCE_SWITCH_MAX)
local SHOUTOUT_VEH = nil
local FORCE_SWAP_CAM = false
local UPDATE_UI = hptimer()
local LAST_CHANGE_REASON = ""
local LAST_CHANGE_REASON_TRY = ""

-- -----------------------------------------------------------------
-- Common
local function dist3d(p1, p2)
	return math.sqrt((p2.x - p1.x)^2 + (p2.y - p1.y)^2 + (p2.z - p1.z)^2)
end

local function getClosestVehicleToPos(pos_vec, max_dist)
	local closest = {veh = nil, dist = 1e10}
	for _, vehicle in ipairs(getAllVehicles()) do
		if vehicle:getActive() then
			local dist = dist3d(pos_vec, vehicle:getPosition())
			if dist < max_dist and dist < closest.dist then
				closest.veh = vehicle
				closest.dist = dist
			end
		end
	end
	return closest.veh
end

local function splitByNewline(string)
	local lines = {}
	for str in string:gmatch("[^\r\n]+") do
		table.insert(lines, str)
	end
	
	return lines
end

local function splitBy(string, delimeter, convert_into)
	local t = {}
	for str in string.gmatch(string, "([^"..delimeter.."]+)") do
		if convert_into == 1 then -- number
			table.insert(t, tonumber(str))
			
		elseif convert_into == 2 then -- bool
			if str:lower() == "false" then
				table.insert(t, false)
			elseif str:lower() == "true" then
				table.insert(t, false)
			end
			
		else -- string
			table.insert(t, str)
		end
	end
	return t
end

local function hasLineOfSight(from_vec, to_vec)
	local dir_vec = (to_vec - from_vec):normalized()
	local dist = dist3d(from_vec, to_vec)
	
	local hit_dist = castRayStatic(from_vec, dir_vec, dist)
	if hit_dist < dist then
		return false, dist
	end
	return true, dist
end

-- -----------------------------------------------------------------
-- BeamMP Common
local function isBeamMPSession()
	if MPCoreNetwork then return MPCoreNetwork.isMPSession() end
	return false
end

local function getPlayerName(veh_id)
	if not isBeamMPSession() then return nil end
	return (MPVehicleGE.getVehicleByGameID(veh_id) or{}).ownerName
end

local function gameVehicleIDToServerVehicleID(veh_id)
	local server_vehicle_id = MPVehicleGE.getServerVehicleID(veh_id)
	if not server_vehicle_id or server_vehicle_id == -1 then return end
	return server_vehicle_id
end

local function serverVehicleIDToGameVehicleID(server_vehicle_id)
	local veh_id = MPVehicleGE.getGameVehicleID(server_vehicle_id)
	if not veh_id or veh_id == -1 then return end
	return veh_id
end

-- -----------------------------------------------------------------
-- Load Common
local function loadSettings(level_name)
	local settings_path = '/shoutcast_prefabs/' .. level_name .. '/settings.json'
	if not FS:fileExists(settings_path) then
		log("W", "Shoutcast", 'No settings available')
		return
	end
	local handle = io.open(settings_path, 'r')
	if handle == nil then
		log("W", "Shoutcast", 'Cannot open settings file in read mode')
		return
	end
	local data = handle:read("*all")
	handle:close()
	
	local data = jsonDecode(data)
	if not data then
		log("W", "Shoutcast", "Cannot decode settings file")
		return
	end
	
	DISTANCE_SWITCH_MIN = data.DISTANCE_SWITCH_MIN
	DISTANCE_SWITCH_MAX = data.DISTANCE_SWITCH_MAX
	IGNORE_FURTHER_THEN = data.IGNORE_FURTHER_THEN
	TIME_LIFE_MIN = data.TIME_LIFE_MIN
	TIME_LOST_LOS_MIN = data.TIME_LOST_LOS_MIN
	PRE_POS_TIME = data.PRE_POS_TIME
	log('I', "Shoutcast", 'Loaded settings')
end

local function evalGroupPositionFromPrefab(prefab_path)
	local handle = io.open(prefab_path, 'r')
	if handle == nil then return '0 0 0' end
	local data = handle:read("*all")
	handle:close()
	
	for _, line in ipairs(splitByNewline(data)) do
		if line:find('"class":"SimGroup"') then
			return (jsonDecode(line) or {}).groupPosition or "0 0 0"
			--[[
			return vec3(
				unpack(
					splitBy(
						(jsonDecode(line) or {}).groupPosition or "0 0 0"
						,
						' ',
						1
					)
				)
			)
			]]
		end
	end
	return '0 0 0'
end

local function loadPrefab(level_name)
	local prefab_path = '/shoutcast_prefabs/' .. level_name .. '/default.prefab.json'
	if not FS:fileExists(prefab_path) then
		log("E", "Shoutcast", 'No prefab available for this map')
		return
	end
	
	local obj = spawnPrefab(
		ROOT_GROUP, -- name
		prefab_path, -- file path
		evalGroupPositionFromPrefab(prefab_path), -- pos
		'0 0 1 0', -- rot
		'1 1 1' -- scale
	)
	return obj
end

local function learnFromRootGroup(simgroup)
	if simgroup == nil then
		log("E", "Shoutcast", 'No Scenetree group or prefab with the name "' .. ROOT_GROUP .. '"')
		return false
	end
	
	local class_name = simgroup:getClassName()
	if class_name ~= "SimGroup" then
		if class_name == "Prefab" then
			simgroup = simgroup:getChildGroup()
		else
			log("E", "Shoutcast", 'No Scenetree group or prefab with the name "' .. ROOT_GROUP .. '"')
			return
		end
	end
	
	for i = 0, simgroup:getCount() do
		local scene_obj = scenetree.findObjectById(simgroup:idAt(i))
		if scene_obj.getPosition then
			table.insert(CAMERAS, {
				pos = scene_obj:getPosition()
			})
		end
	end
end

-- -----------------------------------------------------------------
-- Camera common
local function evalValidCamerasByLOS(to_vec)
	local cams = {}
	for _, cam in ipairs(CAMERAS) do
		local has_los, dist = hasLineOfSight(cam.pos, to_vec)
		if has_los and dist < IGNORE_FURTHER_THEN then
			table.insert(cams, {
				ref = cam,
				dist = dist
			})
		end
	end
	return cams
end

local function evalClosestCamByLOS(to_vec, ignore_ref)
	local cams = evalValidCamerasByLOS(to_vec)
	if #cams == 0 then return end
	
	local closest = {dist = 1e10}
	for _, cam in ipairs(cams) do
		if cam.dist < closest.dist then
			if not ignore_ref or ignore_ref.pos ~= cam.ref.pos then
				closest = cam
			end
		end
	end
	return closest.ref
end

--[[
local function evalRandomClosestCamByLOS(to_vec)
	local cams = evalValidCamerasByLOS(to_vec)
	if #cams == 0 then return end
	
	local range = cams[1].dist * 1.2
	local selectable = {}
	for _, cam in ipairs(cams) do
		if cam.dist < range then
			table.insert(selectable, cam)
		end
	end
	
	dump(#selectable, selectable)
	return selectable[math.random(1, #selectable)].ref
end
]]

-- -----------------------------------------------------------------
-- Runtime
local function updateUI(target_obj)
	if not DRAW_UI then return end
	if UPDATE_UI:stop() < 100 then return end
	UPDATE_UI:stopAndReset()
	
	local tar_pos = target_obj:getPosition()
	local cams_with_los = #evalValidCamerasByLOS(tar_pos)
	local has_los, dist = hasLineOfSight(C_CAMERA.pos, tar_pos)
	dist = math.floor(dist)
	local life_time_p = math.min(100, math.floor((CAM_LIFE_TIME:stop() / TIME_LIFE_MIN) * 100))
	local life_time_of = TIME_LIFE_MIN / 1000
	--local fov = math.floor(C_FOV)
	local range_p = math.min(100, math.floor((dist / DISTANCE_SWITCH_NEXT) * 100))
	local spectating = getPlayerName(target_obj:getId()) or "YOU"
	local los_loss_p = math.min(100, math.floor((LOST_LOS:stop() / TIME_LOST_LOS_MIN) * 100))
	local can_receive_shoutout = "Broadcast disabled"
	if ACCEPT_SHOUTOUTS then can_receive_shoutout = "Broadcast enabled" end
	
	guihooks.message({txt = string.format(
		[[
			SHOUTCAST CAM ACTIVE - %s
			%s
			----------Conditions----------
			1. Next Cam...: %s (Available: %s Max: %sm)
			2. Lifetime......: %s (%s%% / %ss)
			3. Range.........: %s (%s%% / %sm)
			3. or LOS loss.: %s (%s%% / %sms)
			Last Change...: %s
		]],
			spectating,
			can_receive_shoutout,
			cams_with_los > 1, cams_with_los, IGNORE_FURTHER_THEN,
			life_time_p > 99, life_time_p, life_time_of,
			range_p > 99, range_p, DISTANCE_SWITCH_NEXT,
			not has_los, los_loss_p, TIME_LOST_LOS_MIN,
			LAST_CHANGE_REASON
		)},
		1,
		"shoutcasting"
	)
end

local function updateCam(target_obj)
	local cam_name = core_camera.getActiveCamName()
	if cam_name ~= CAM_NAME then
		if cam_name ~= "free" then
			core_camera.setByName(CAM_NAME)
		else
			return nil
		end
	end
	
	local tar_pos = target_obj:getPosition()
	local cam_pos = C_CAMERA.pos
	local dist = dist3d(tar_pos, cam_pos)
	local pre_pos
	if simTimeAuthority.getPause() then
		pre_pos = tar_pos
	else
		local tar_vel = target_obj:getVelocity()
		local factor = math.min(1, tar_vel:length() / 5)
		pre_pos = tar_pos + (factor * (tar_vel * PRE_POS_TIME))
	end
	
	core_camera:setPosition(vec3(C_CAMERA.pos))
	core_camera:setRotation(quatFromDir(
		(pre_pos - cam_pos):normalized(),
		vec3(0, 0, 1)
	))
	C_FOV = math.max(0, 40 - (dist / 2))
	core_camera:setFOV(C_FOV)
end

M.onPreRender = function()
	if not INITIALIZED then return end
	if SHOUTOUT_VEH then
		local pos = SHOUTOUT_VEH:getSpawnWorldOOBB():getCenter()
		debugDrawer:drawCircle(pos, 5, 20, Point4F(0, 1, 0, 1))
		pos.z = pos.z + 2
		debugDrawer:drawText(pos, 'CLICK AGAIN TO BROADCAST', ColorF(1, 1, 1, 1))
	end
	
	if not IS_RUNNING then return end
	
	local vehicle = getPlayerVehicle(0)
	if not vehicle then return end
	local to_vec = vehicle:getPosition()
	
	if not C_CAMERA then
		C_CAMERA = evalClosestCamByLOS(to_vec)
		if not C_CAMERA then return end
		CAM_LIFE_TIME:stopAndReset()
	end
	
	local try_switch = false
	
	if not hasLineOfSight(C_CAMERA.pos, to_vec) then
		if LOST_LOS:stop() > TIME_LOST_LOS_MIN then
			--dump(123, LOST_LOS:stop())
			LAST_CHANGE_REASON_TRY = "Lost LOS"
			try_switch = true
		end
	else
		LOST_LOS:stopAndReset()
	end
	
	--print(dist3d(C_CAMERA.pos, to_vec))
	if dist3d(C_CAMERA.pos, to_vec) > DISTANCE_SWITCH_NEXT then
		LAST_CHANGE_REASON_TRY = "Range exceeded"
		try_switch = true
	end
	
	if FORCE_SWAP_CAM or (try_switch and CAM_LIFE_TIME:stop() > TIME_LIFE_MIN) then
		local ignore = nil
		if FORCE_SWAP_CAM then
			ignore = C_CAMERA
			LAST_CHANGE_REASON_TRY = "Manual change"
		end
		FORCE_SWAP_CAM = false
		
		local cam = evalClosestCamByLOS(to_vec, ignore)
		if cam and cam.pos ~= C_CAMERA.pos then
			--table.insert(AVG_LIFE_TIME, CAM_LIFE_TIME:stop())
			--local total = 0
			--for _, avg in ipairs(AVG_LIFE_TIME) do
			--	total = total + avg
			--end
			--print("Average life time: " .. math.floor(total / #AVG_LIFE_TIME) .. ' ms')
			
			C_CAMERA = cam
			CAM_LIFE_TIME:stopAndReset()
			DISTANCE_SWITCH_NEXT = math.random(DISTANCE_SWITCH_MIN, DISTANCE_SWITCH_MAX)
			LAST_CHANGE_REASON = LAST_CHANGE_REASON_TRY
		end
	end
	
	updateUI(vehicle)
	updateCam(vehicle)
	
	
	if DRAW_DEBUG then
		-- draw when next cam is chosen if no static is in the way
		local color = Point4F(0, 1, 0, 1)
		if dist3d(C_CAMERA.pos, to_vec) > DISTANCE_SWITCH_NEXT then color = Point4F(1, 0, 0, 1) end
		debugDrawer:drawCircle(C_CAMERA.pos, DISTANCE_SWITCH_NEXT, 30, color)
		debugDrawer:drawLine(C_CAMERA.pos, to_vec, ColorF(1, 1, 1, 1))
		--debugDrawer:drawText(C_CAMERA.pos, "Life time: " .. math.floor(CAM_LIFE_TIME:stop()) .. ' ms', ColorF(1, 1, 1, 1))
		
		-- draw all cams and if in range and in sight
		for _, cam in ipairs(CAMERAS) do
			local pos = vec3(cam.pos.x, cam.pos.y, cam.pos.z + 2)
			local color = ColorF(0, 1, 0, 1)
			local txt = "OK"
			
			local has_los, dist = hasLineOfSight(cam.pos, to_vec)
			if not has_los then color = ColorF(1, 1, 0, 1) txt = "No LOS" end
			if dist > IGNORE_FURTHER_THEN then color = ColorF(1, 0, 0, 1) txt = "To far" end
			
			debugDrawer:drawSphere(pos, 1, color)
			debugDrawer:drawText(pos, txt, color)
		end
		
		-- draw cams able to spot the vehicle
		debugDrawer:drawCircle(to_vec, IGNORE_FURTHER_THEN, 30, Point4F(0, 0, 0, 1))
		debugDrawer:drawText(vec3(to_vec.x, to_vec.y, to_vec.z + 2), #evalValidCamerasByLOS(to_vec) .. ' cams have LOS', ColorF(1, 1, 1, 1))
	end
end

-- -----------------------------------------------------------------
-- Init
local function init()
	local level_name = core_levels.getLevelName(getMissionFilename())
	if level_name == nil then return end
	
	CAMERAS = {}
	C_CAMERA = nil
	
	loadSettings(level_name)
	
	local scenetree_group = scenetree[ROOT_GROUP]
	if not scenetree_group then scenetree_group = loadPrefab(level_name) end
	learnFromRootGroup(scenetree_group)
	
	if #CAMERAS > 0 then INITIALIZED = true end
	
	if AddEventHandler then
		AddEventHandler("shoutoutReceive", M.shoutoutReceive)
	end
end

local function unload()
	CAMERAS = {}
	C_CAMERA = nil
	INITIALIZED = false
end

-- -----------------------------------------------------------------
-- Game events
M.onExtensionLoaded = function()
	init()
end

M.onExtensionUnloaded = function()
	unload()
end

M.onClientEndMission = function()
	unload()
end

M.onWorldReadyState = function(state)
	if state == 2 then
		init()
	end
end

-- -----------------------------------------------------------------
-- Hotkeys
M.toggleShoutcast = function()
	if #CAMERAS == 0 then init() end
	IS_RUNNING = not IS_RUNNING
end

M.toggleDebugDraw = function()
	if not IS_RUNNING then return end
	DRAW_DEBUG = not DRAW_DEBUG
end

M.toggleDrawUi = function()
	if not IS_RUNNING then return end
	DRAW_UI = not DRAW_UI
end

M.toggleShoutoutReceive = function()
	if not IS_RUNNING then return end
	ACCEPT_SHOUTOUTS = not ACCEPT_SHOUTOUTS
end

M.forceSwapCam = function()
	if not IS_RUNNING then return end
	FORCE_SWAP_CAM = true
end

M.addLifeTime = function(seconds)
	if not IS_RUNNING then return end
	TIME_LIFE_MIN = math.max(0, TIME_LIFE_MIN + (seconds * 1000))
end

M.addLOSLossTime = function(ms)
	if not IS_RUNNING then return end
	TIME_LOST_LOS_MIN = math.max(0, TIME_LOST_LOS_MIN + ms)
end

M.shoutoutAction = function()
	local vehicle = getClosestVehicleToPos(
		(cameraMouseRayCast() or {}).pos or vec3(0, 0, 0),
		10
	)
	
	if not vehicle then
		SHOUTOUT_VEH = nil
		return
	end
	
	local veh_id = vehicle:getId()
	local message = ''
	
	if SHOUTOUT_VEH and SHOUTOUT_VEH:getId() == veh_id then
		message = 'Broadcasted Shoutout'
		SHOUTOUT_VEH = nil
		M.shoutoutReceive(veh_id)
		
		-- broadcast
		if isBeamMPSession() then
			TriggerServerEvent("shoutoutBroadcast", gameVehicleIDToServerVehicleID(veh_id))
		end
	else
		SHOUTOUT_VEH = vehicle
		message = 'Shoutout: ' .. (getPlayerName(veh_id) or "YOU")
	end
	
	guihooks.trigger('toastrMsg', {
		type = 'info',
		title = '',
		msg = message,
		config = {timeOut = time or 5000}
	})
end

M.shoutoutReceive = function(veh_id)
	if not IS_RUNNING or not ACCEPT_SHOUTOUTS then return end
	if type(veh_id) == "string" then veh_id = serverVehicleIDToGameVehicleID(veh_id) end
	if not veh_id then return end
	
	be:enterVehicle(0, getObjectByID(veh_id))
end

return M