-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_police', 'gameplay_traffic_trafficUtils', 'core_vehicleActivePooling'}

local logTag = 'traffic'

local traffic, trafficAiVehsList, trafficIdsSorted, rolesCache = {}, {}, {}, {}
local mapNodes
local vehPool, vehPoolId
local trafficVehicle = require('gameplay/traffic/vehicle')

-- const vectors --
local vecUp = vec3(0, 0, 1)
local vecY = vec3(0, 1, 0)

-- common functions --
local min = math.min
local max = math.max
local random = math.random

--------
local state = 'off'
local spawnProcess = {}
local spawnPointPos, spawnPointDirVec = vec3(), vec3()
local tempVec = vec3()
local vars, focus

local auxiliaryData = { -- additional data for traffic
  worldLoaded = false, -- world loaded flag
  queuedVehicle = 0, -- current traffic vehicle index
  dynamicSpawnDist = 0, -- dynamic respawn distance ahead for all traffic vehicles
  dynamicSpawnDir = 0, -- dynamic respawn direction bias for all traffic vehicles
  sampleTimer = 0 -- timer for sampling the current traffic conditions
}

local defaultData = { -- safe vehicles to use
  traffic = {model = 'pickup'},
  police = {model = 'fullsize', config = 'police'}
}

local debugColors = { -- used for debug mode
  black = ColorF(0, 0, 0, 1),
  white = ColorF(1, 1, 1, 1),
  green = ColorF(0.2, 1, 0.2, 1),
  red = ColorF(0.5, 0, 0, 1),
  blackAlt = ColorI(0, 0, 0, 255),
  greenAlt = ColorI(0, 64, 0, 255)
}

M.debugMode = false -- visual and logging debug mode
M.showMessages = true -- if enabled, UI messages can be automatically shown

local function getAmountFromSettings() -- gets saved or calculated amount of vehicles
  local amount = settings.getValue('trafficAmount') -- get amount from gameplay settings
  if amount == 0 then -- use CPU-based value
    amount = getMaxVehicleAmount(10)
  end
  return amount
end

local function getIdealSpawnAmount(amount, ignoreAdjust) -- gets the ideal amount of vehicles to spawn based on current world state
  -- this could be improved
  if not amount or amount < 0 then
    amount = getAmountFromSettings()
  end

  local vehCount = 0
  if not ignoreAdjust then
    for _, veh in ipairs(getAllVehiclesByType()) do
      if veh.isParked ~= 'true' and veh:getActive() then
        vehCount = vehCount + 1
      end
    end
  end

  return amount - vehCount
end

local function getNumOfTraffic(activeOnly) -- returns current amount of AI traffic
  return (activeOnly and vehPool) and #vehPool.activeVehs or #trafficAiVehsList
end

local function setFocus(mode, data) -- sets the focus point to use for checking and respawning traffic
  -- The focus system is used by the traffic and parking systems to check if vehicles should be kept active or teleported
  -- It can use the default camera, any player vehicle, or a custom transform
  focus = focus or {} -- initializes here
  if not mode or mode == 'camera' then -- resets focus (default mode is camera)
    focus.mode = 'camera'
    focus.pos = vec3()
    focus.dirVec = vec3()
    focus.dist = 0 -- scales direction vector (looks ahead)
    if not mode then focus.auto = false end
    return
  end

  data = data or {}
  if mode == 'vehicle' then
    focus.mode = 'vehicle'
    focus.vehId = data.vehId or be:getPlayerVehicleID(0)
  elseif mode == 'custom' then
    focus.mode = 'custom'
    focus.pos:set(data.pos)
    focus.dirVec:set(data.dir)
    focus.dist = data.dist
    focus.auto = data.auto and true or false -- if true, mode automatically changes, for example if the player vehicle is switched
  end
end
setFocus()

local function getFocus() -- returns the focus point
  if not focus then setFocus() end -- just in case
  return focus
end

local function setMapData() -- updates all map related data
  mapNodes = map.getMap().nodes
  --mapRules = map.getRoadRules()
end

local function getNextSpawnPoint(id, spawnData, placeData) -- sets the new spawn point of a vehicle
  if id and getObjectByID(id) then
    local playerId = be:getPlayerVehicleID(0)
    if not spawnData then
      local spawnValue = traffic[id] and traffic[id].respawn.spawnValue or 1
      if spawnValue > 0 then -- respawning is enabled
        spawnValue = clamp(spawnValue, 0.05, 5)
        local freeCamMode = commands.isFreeCamera() or not traffic[playerId]
        spawnPointPos:set(focus.pos)
        spawnPointDirVec:set(focus.dirVec)
        local speedValue = min(150, square(math.abs(focus.dist or 0) * 0.15)) -- affects spawn point distance and deviation
        local addedDist = speedValue
        local height = max(-1e6, be:getSurfaceHeightBelow(spawnPointPos))

        if freeCamMode then -- if free camera, the added distance is based on height from ground (can make vehicles respawn further away)
          addedDist = spawnPointPos.z - height
          addedDist = clamp(square(addedDist) / 15, 0, 200)
        end
        addedDist = addedDist + random() * auxiliaryData.dynamicSpawnDist -- distance scattering; perhaps this should be stronger if there are very many vehicles

        if focus.dist < 1 and random() < 0.25 then -- randomly try reverse direction if player is stationary
          spawnPointDirVec:setScaled(-1)
          addedDist = 0
        end

        local baseValue = clamp(50 + 50 / spawnValue, 50, 400) -- base value to use for initial distance
        local minDist = baseValue + addedDist -- spawn search initial distance
        local maxDist = clamp(minDist * 3, 200, 1200) -- spawn search final distance
        local targetDist = baseValue + minDist -- spawn search visible distance (static raycast)
        local spawnRandomValue = traffic[id] and traffic[id].respawn.spawnRandomization or 1 -- spawn search scatter randomness
        local lateralDist = spawnRandomValue * clamp(100 - speedValue, 0, 40 + (spawnPointPos.z - height)) * 0.25 -- side offset (amplified by height)

        if lateralDist ~= 0 then -- adjacent roads may be used with lateral offset to start position
          tempVec:setCross(spawnPointDirVec, vecUp)
          tempVec:setScaled(lerp(-lateralDist, lateralDist, random()))
          spawnPointPos:setAdd(tempVec)
        end

        local params = {}
        params.pathRandomization = freeCamMode and 1 or clamp((100 - speedValue) / 80, 0, spawnRandomValue) -- pathfinder randomization (higher value is more random)

        if traffic[id] then
          -- roads with a drivability < 1 will have a much lower chance of being usable
          params.minDrivability = clamp(math.log10(10 * random() + 1) * 0.9, min(1, traffic[id].drivability), 1)
        end

        spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(spawnPointPos, spawnPointDirVec, minDist, maxDist, targetDist, params)
      end
    end
  end

  if spawnData then
    if not placeData then
      -- this needs improvement
      local dirBias = traffic[id] and traffic[id].respawn.spawnDirBias or 0
      if dirBias == 0 then
        tempVec:setSub2(spawnData.pos, focus.pos)
        if focus.dist < 1 or focus.dirVec:dot(tempVec) < 0 then
          dirBias = 0.6 -- vehicles respawning on the path behind should mostly drive towards you
        else
          dirBias = auxiliaryData.dynamicSpawnDir -- smart direction scattering
        end
      end

      placeData = {dirRandomization = dirBias}
    end
    placeData.legalDirection = true

    local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, placeData)
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vecY:rotated(quatFromDir(dir, normal)), normal)

    if traffic[id] and spawnData.n1 and spawnData.n2 then
      -- speed boost after respawning (if enabled)
      if traffic[id].hasTrailer then
        traffic[id].respawnSpeed = -1 -- this seems to help with attaching trailer
      elseif (map.getNodeLinkCount(spawnData.n2) > 2 and pos:squaredDistance(mapNodes[spawnData.n2].pos) < 400) then -- is near intersection
        traffic[id].respawnSpeed = nil
      else
        traffic[id].respawnSpeed = max(3.333, dir:dot(vecUp) * 30) -- 12 km/h, or higher if uphill is steep enough
        local link = mapNodes[spawnData.n1].links[spawnData.n2] or mapNodes[spawnData.n2].links[spawnData.n1]
        if link then
          traffic[id].respawnSpeed = max(traffic[id].respawnSpeed, (link.speedLimit - 8.333) * 0.5) -- bigger speed boost at higher speed limits
        end
      end
    end

    return pos, rot
  end
end

local function respawnVehicle(id, pos, rot, strict) -- moves the vehicle to a new position and rotation
  local obj = id and getObjectByID(id)
  if not obj or not pos or not rot then return end

  if not strict then
    spawn.safeTeleport(obj, pos, rot, true, nil, false) -- this is slower, but prevents vehicles from spawning inside static geometry
  else
    rot = rot * quat(0, 0, 1, 0)
    obj:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    obj:autoplace(false)
    obj:resetBrokenFlexMesh()
  end

  if traffic[id] then
    traffic[id].pos = vec3(pos) -- instantly updates the position this frame
    traffic[id]._teleport = nil
    traffic[id]._teleportDist = nil
    traffic[id]:onRespawn()
  end
end

local function forceTeleport(id, pos, dir, minDist, maxDist, targetDist) -- force teleports a traffic vehicle
  if traffic[id] and traffic[id].ignoreForceTeleport then return end -- ignoreForceTeleport is a special flag for vehicles that should not be force teleported

  local vehObj = getObjectByID(id)
  if vehObj and vehObj:getActive() then
    setMapData()

    pos = pos or core_camera.getPosition()
    dir = dir or core_camera.getForward()
    minDist = minDist or 100
    maxDist = maxDist or 500
    targetDist = targetDist or min(minDist * 2, lerp(minDist, maxDist, 0.5))

    --if traffic[id] then
      --traffic[id].respawn.pos = vec3(0, 0, -1000) -- temporary, prevents conflicts (remove later)
    --end

    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(nil, nil, minDist, maxDist, targetDist)
    local newPos, newRot = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, {legalDirection = true})
    newRot = quatFromDir(newRot, map.surfaceNormal(newPos))
    respawnVehicle(id, newPos, newRot)
  end
end

local function scatterTraffic(vehIds, minDist, maxDist) -- teleports a group of vehicles away from the current place
  vehIds = vehIds or trafficAiVehsList -- all AI-controlled traffic by default
  for _, id in ipairs(vehIds) do
    forceTeleport(id, nil, nil, minDist, maxDist)
  end
end

local function createTrafficPool(idList) -- sets the main traffic vehicle pooling object
  -- this manages the active and inactive simulation states of the vehicles, as well as enforcing a maximum amount of active vehicles at any point in time
  if not core_vehicleActivePooling then extensions.load('core_vehicleActivePooling') end
  vehPool = core_vehicleActivePooling.createPool()
  vehPool.name = 'traffic'
  vehPoolId = vehPool.id

  if idList then
    for _, id in ipairs(idList) do
      vehPool:insertVeh(id)
    end
  end
end

local function deleteTrafficPool() -- deletes the traffic pool and resets variables
  if vehPool then
    vehPool:deletePool(true)
    vehPool, vehPoolId = nil, nil
  end
  vars.activeAmount = math.huge
end

local function updateTrafficPool() -- updates the main traffic vehicle pooling object
  if not vehPool then return end
  vehPool:setMaxActiveAmount(vars.activeAmount)
  vehPool:setAllVehs(true)
end

local function getNextVehFromPool() -- returns the next usable inactive vehicle, or nil if none found
  if vehPool then
    local pool = vehPool
    if vehPool.prevPoolId and core_vehicleActivePooling.getPoolById(vehPool.prevPoolId) then -- alternate vehicle pool for cycling (currently unused)
      pool = core_vehicleActivePooling.getPoolById(vehPool.prevPoolId)
    end

    for _, id in ipairs(pool.inactiveVehs) do
      if traffic[id] then
        local activeProbability = traffic[id].enableRespawn and traffic[id].activeProbability or 0
        if activeProbability >= random() then -- vehicles are less likely to get activated if they have a lower probability value
          return id
        end
      end
    end
  end
end

local function processNextSpawn(id, ignorePool) -- processes the next vehicle respawn action
  local newPos, newRot
  local oldId, newId = id, id
  local tempId

  if not ignorePool and traffic[id].enableAutoPooling then
    tempId = getNextVehFromPool()
    if tempId then
      if #vehPool.activeVehs < vehPool.maxActiveAmount then -- amount of active vehicles is less than the expected limit
        newId = tempId
      else
        oldId, newId = vehPool:crossCycle(vehPool.prevPoolId, oldId, tempId) -- cycles the pool; if a previous pool exists, use a vehicle from there
      end
    end
  end

  if vehPool.allVehs[newId] == 0 then -- if vehicle is still inactive, set it to active
    vehPool:setVeh(newId, true)
  end
  newPos, newRot = getNextSpawnPoint(newId)
  if newPos then
    respawnVehicle(newId, newPos, newRot)
  else
    if not tempId then
      traffic[newId]:onRefresh() -- refreshes the vehicle in place (only if it didn't get cycled)
    else
      forceTeleport(newId, nil, -focus.dirVec) -- force teleports the vehicle behind the player view (not an ideal solution)
    end
  end
end

local function refreshVehicles() -- resets core traffic vehicle data
  for _, veh in pairs(traffic) do
    veh:onRefresh()
  end
end

local function resetTrafficVars() -- resets traffic variables to default
  vars = {
    spawnValue = 1, -- as the default value, globalSpawnDist will dynamically adjust the random respawn distance from player
    spawnDirBias = 0, -- as the default value, globalSpawnDir will dynamically adjust the random respawn direction
    activeAmount = math.huge, -- number of active (visible) vehicles at a time
    baseAggression = 0.35, -- old default: 0.3
    speedLimit = nil, -- global speed limit; overrides road speed limits
    aiMode = 'traffic',
    aiAware = 'auto',
    aiDebug = 'off',
    enableRandomEvents = false -- enables events such as police randomly chasing AI suspects
  }

  refreshVehicles()
end
resetTrafficVars()

local function setTrafficVars(data, reset) -- sets various traffic variables
  if reset then resetTrafficVars() end
  if type(data) ~= 'table' then return end

  for k, v in pairs(data) do
    if k == 'aiMode' or k == 'aiDebug' or k == 'aiAware' then
      data[k] = type(v) == 'string' and string.lower(v) or v
    end
  end

  vars = tableMerge(vars, data)

  for _, id in ipairs(trafficAiVehsList) do
    local veh = traffic[id]

    if data.aiMode then
      veh:setAiMode(data.aiMode)
    end
    if data.aiAware or data.speedLimit or data.baseAggression then
      veh:setAiParameters(data)
    end
    if data.spawnValue then
      veh.respawn.spawnValue = data.spawnValue
      auxiliaryData.dynamicSpawnDist = 0 -- resets distance scattering
    end
    if data.spawnDirBias then
      veh.respawn.spawnDirBias = data.spawnDirBias
      auxiliaryData.dynamicSpawnDir = 0 -- resets direction scattering
    end

    if data.aiMode then
      -- here is special logic that sets or unsets roles if a different AI mode is set
      -- in other words, this enables modes such as 'flee' or 'chase' to work seamlessly for all vehicles
      if data.aiMode == 'traffic' and veh.roleName == 'empty' then
        veh:setRole(veh._tempRole) -- restores the previous role (or auto role if no previous role was set)
        veh._tempRole = nil
      elseif data.aiMode ~= 'traffic' and veh.roleName ~= 'empty' then
        veh._tempRole = veh.roleName
        veh:setRole('empty') -- prevents role logic from changing AI mode internally
      end
    end
  end

  if data.aiDebug then
    M.debugMode = data.aiDebug == 'traffic'
    gameplay_traffic_trafficUtils.debugMode = M.debugMode
    refreshVehicles()
  end
  if data.activeAmount and vehPool and state == 'on' then -- state needs to be on (not loading) for this to work
    updateTrafficPool()
  end
end

local function setDebugMode(value) -- sets the module debug mode
  value = value and 'traffic' or 'off'
  setTrafficVars({aiDebug = value})
end

local function setActiveAmount(amount) -- sets the maximum amount of active (visible) vehicles
  amount = amount or math.huge
  setTrafficVars({activeAmount = amount})
end

local function getRoleConstructor(roleName) -- gets the role constructor module
  if not rolesCache[roleName] then
    if not FS:fileExists('/lua/ge/extensions/gameplay/traffic/roles/'..roleName..'.lua') then
      log('W', logTag, 'Traffic role does not exist: '..roleName)
      roleName = 'standard'
    end
    rolesCache[roleName] = require('/lua/ge/extensions/gameplay/traffic/roles/'..roleName) -- caches the role constructor
  end
  return rolesCache[roleName]
end

local function insertTraffic(id, ignoreAi, ignoreVehPool) -- inserts new vehicles into the traffic table
  -- ignoreAi prevents AI and respawn logic from getting applied to the given vehicle
  -- ignoreVehPool prevents the vehicle from becoming deactivated due to the vehicle pooling system (maybe needs another way to handle this)
  local obj = getObjectByID(id)

  if obj and not traffic[id] then
    traffic[id] = trafficVehicle({id = id})
    if not traffic[id] then -- traffic vehicle object creation failed
      return
    end

    if not ignoreAi then
      table.insert(trafficAiVehsList, id)
      gameplay_walk.addVehicleToBlacklist(id)

      obj:setDynDataFieldbyName('isTraffic', 0, 'true') -- this can be used by other systems to quickly check if this vehicle is only meant for traffic
      obj.playerUsable = settings.getValue('trafficEnableSwitching') and true or false

      if not vehPool then
        createTrafficPool()
      end
      if not ignoreVehPool then
        vehPool:insertVeh(id)
      end

      if not next(map.getMap().nodes) then -- always disable respawning if no map nodes exist
        traffic[id].enableRespawn = false
        traffic[id].ignoreForceTeleport = true
      end

      traffic[id]:setAiMode(obj.aiMode or vars.aiMode) -- object ai mode can overwrite traffic default ai mode
    end

    trafficIdsSorted = tableKeysSorted(traffic)
    extensions.hook('onTrafficVehicleAdded', id)
  end
end

local function removeTraffic(id, stopAi) -- removes vehicles from the traffic table
  if traffic[id] then
    local obj = getObjectByID(id)
    local idx = arrayFindValueIndex(trafficAiVehsList, id)
    if idx then table.remove(trafficAiVehsList, idx) end

    if obj then
      traffic[id].role:resetAction()
      obj:setMeshAlpha(1, '')
      obj.playerUsable = true
      obj.uiState = 1

      if stopAi and traffic[id].isAi then
        obj:queueLuaCommand('ai.setMode("stop")')
      end
      if vehPool then
        vehPool:removeVeh(id)
      end
    end

    traffic[id] = nil
    trafficIdsSorted = tableKeysSorted(traffic)
    extensions.hook('onTrafficVehicleRemoved', id)
  end

  if vehPool and not trafficAiVehsList[1] then
    deleteTrafficPool()
  end
end

local function checkPlayer(id) -- checks if the player data needs to be inserted
  -- the player vehicle should ideally be included in the traffic table at all times
  if state == 'on' then
    local obj = getObjectByID(id)

    if obj and obj:isPlayerControlled() and not obj.ignoreTraffic then
      if traffic[id] then
        if traffic[id].alpha ~= 1 then -- if vehicle was invisible, show it
          obj:setMeshAlpha(1, '')
          traffic[id].alpha = 1
        end
      else
        insertTraffic(id, true)
      end
      if focus.auto then
        setFocus('vehicle', {vehId = id}) -- updates the focus data with the new id
      end
    end
  end
end

local function onVehicleSpawned(id)
  if traffic[id] then -- if vehicle is replaced, update its traffic role and properties
    traffic[id]:applyModelConfigData()
    traffic[id]:setRole(traffic[id].autoRole)
    traffic[id]:resetAll()
  end
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleSwitched(oldId, newId)
  checkPlayer(newId)
end

local function onVehicleResetted(id)
  checkPlayer(id)
  if traffic[id] then
    traffic[id]:onVehicleResetted()
  end
end

local function onVehicleDestroyed(id)
  removeTraffic(id)
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleActiveChanged(vehId, active)
  if vehPool then
    if not vehPool.allVehs[vehId] then
      vehPool._updateFlag = true
    end

    if traffic[vehId] and traffic[vehId].isAi then
      if not active then
        traffic[vehId]._teleport = true
        traffic[vehId].alpha = 0
        getObjectByID(vehId):setMeshAlpha(0, '')
      else
        if traffic[vehId]._teleport then -- force teleport if flag exists
          if gameplay_traffic_trafficUtils.checkSpawnPoint(traffic[vehId].pos) then -- if current position is safe, then no teleport needed
            traffic[vehId]:onRefresh()
          else
            forceTeleport(vehId, nil, nil, traffic[vehId]._teleportDist)
          end
        end
      end
    end
  end
end

local function deleteVehicles() -- deletes all traffic vehicles
  for _, veh in ipairs(getAllVehiclesByType()) do
    local id = veh:getId()
    if traffic[id] and (traffic[id].isAi or tonumber(veh.isTraffic) == 1) then
      removeTraffic(id)
      veh:delete()
    end
  end
end

local function activate(vehList, ignoreFilter) -- activates traffic mode, and adds specified vehicles to the traffic table
  if type(vehList) ~= 'table' then -- for backwards compatibility
    vehList = {}

    -- NOTE: If vehList is empty, all vehicles get activated, even unintended ones; this may need to be reconsidered in the future
    for _, veh in ipairs(getAllVehiclesByType()) do
      if not veh.isParked then
        table.insert(vehList, veh:getId())
      end
    end
  end

  if not vehList[1] then
    --log('W', logTag, 'No vehicles found; unable to start traffic!')
    return
  end

  table.sort(vehList, function(a, b) return a < b end)

  for _, id in ipairs(vehList) do
    if type(id) == 'number' then
      map.request(id, -1) -- force mapmgr to read map (performance optimization)
      insertTraffic(id, getObjectByID(id):isPlayerControlled())
    end
  end
end

local function deactivate(stopAi) -- deactivates traffic mode for all vehicles
  for _, id in ipairs(tableKeysSorted(traffic)) do
    removeTraffic(id, stopAi)
  end
end

local function spawnTraffic(amount, group, options) -- spawns a defined group of vehicles and sets them as traffic
  amount = amount or max(1, getAmountFromSettings() - #getAllVehiclesByType()) -- if amount nil, automatically sets a limited amount to save performance
  group = group or core_multiSpawn.createGroup(amount)
  options = type(options) == 'table' and options or {}
  state = 'spawning'

  local spawnMode = next(map.getMap().nodes) and 'traffic' or 'lineAhead' -- check if map nodes exist
  if not options.pos and spawnMode == 'traffic' then
    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(nil, nil, options.minDist or 0, options.maxDist or 200, 0)
    if core_camera.getPosition():squaredDistance(spawnData.pos or vecUp) >= 100 then -- camera is far enough from spawn point
      options.pos, options.dir = spawnData.pos, spawnData.dir -- sets custom position and direction
      log('I', logTag, 'Spawn point found outside of default spawn range')
    end
  end

  return core_multiSpawn.spawnGroup(group, amount, {name = 'autoTraffic', mode = options.mode or spawnMode, gap = options.gap or 20, pos = options.pos, dir = options.dir,
  ignoreJobSystem = not auxiliaryData.worldLoaded, ignoreAdjust = not auxiliaryData.worldLoaded})
end

local function setupTraffic(amount, policeRatio, options) -- prepares a group of vehicles for traffic
  amount = amount or -1
  policeRatio = policeRatio or 0 -- can be between 0 and 1
  options = type(options) == 'table' and options or {}

  if not options.ignoreDelete then
    deleteVehicles() -- clear current traffic
  end
  deleteTrafficPool()

  local trafficGroup, policeGroup
  local policeAmount = 0
  local activeAmount = options.activeAmount or amount

  if type(options.vehGroup) == 'table' then -- directly sets a vehicle group to be used for traffic; may overwrite other parameters
    trafficGroup = options.vehGroup
    log('I', logTag, 'Applying custom traffic group')
  end

  if amount == -1 then -- auto amount
    local amountFromSettings = getAmountFromSettings()
    amount = getIdealSpawnAmount(amountFromSettings) -- maxAmount automatically accounts for currently spawned non-traffic vehicles
    policeAmount = options.policeAmount or math.ceil(amount * policeRatio)
    activeAmount = amount

    if settings.getValue('trafficExtraVehicles') then -- extra amount of vehicles to spawn (they will be inactive when the vehicle pooling system starts)
      local extraAmount = settings.getValue('trafficExtraAmount')
      if extraAmount == 0 then
        extraAmount = clamp(amountFromSettings, 2, 8)
      end

      amount = max(amountFromSettings, amount + extraAmount)
    end
  else
    if options.autoAdjustAmount then
      amount = getIdealSpawnAmount(amount) -- adjust for amount of existing active vehicles
    end
    policeAmount = options.policeAmount or math.ceil(amount * policeRatio)
  end

  if not trafficGroup then -- if predefined vehicle group does not exist, create it
    if policeAmount >= 1 then
      policeAmount = min(policeAmount, amount)
      local fileData, fileName
      local fileMode = options.autoLoadFromFile or settings.getValue('trafficSmartSelections')
      if fileMode then
        fileData, fileName = gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'police'}) -- level specific police vehicles
        if fileData then
          fileData = core_multiSpawn.fitGroup(fileData, policeAmount)
          log('I', logTag, 'Loaded police group from file: '..tostring(fileName))
        end
      end
      policeGroup = fileData or gameplay_traffic_trafficUtils.createPoliceGroup(policeAmount)

      if not policeGroup[1] then
        for i = 1, policeAmount do
          table.insert(policeGroup, defaultData.police)
        end
      end
    end

    if amount >= 1 then
      if not trafficGroup then
        local fileData, fileName
        local fileMode = options.autoLoadFromFile and not (settings.getValue('trafficSimpleVehicles') or options.simpleVehs)
        if fileMode then
          fileData, fileName = gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'traffic'}) -- level specific civilian vehicles
          if fileData then
            fileData = core_multiSpawn.fitGroup(fileData, amount)
            log('I', logTag, 'Loaded traffic group from file: '..tostring(fileName))
          end
        end

        trafficGroup = fileData or gameplay_traffic_trafficUtils.createTrafficGroup(amount, options.allMods, options.allConfigs, options.simpleVehs)
      end
      if not trafficGroup[1] then
        for i = 1, amount do
          table.insert(trafficGroup, defaultData.traffic)
        end
      end

      if policeGroup then
        for i = 1, policeAmount do
          if policeGroup[i] then
            table.insert(trafficGroup, 1, policeGroup[i]) -- pushes to array (police vehicles have priority)
            table.remove(trafficGroup, #trafficGroup) -- pops from array
          end
        end
      end
    end
  end

  if amount > 0 and trafficGroup and trafficGroup[1] then
    spawnProcess.group = trafficGroup
    spawnProcess.amount = amount

    local multiSpawnOptions = {}
    multiSpawnOptions.pos = options.pos
    multiSpawnOptions.rot = options.rot
    if next(multiSpawnOptions) then spawnProcess.multiSpawnOptions = multiSpawnOptions end
    state = 'loading'

    createTrafficPool()
    setTrafficVars({aiMode = 'traffic', activeAmount = activeAmount})
  else
    if amount <= 0 then
      log('I', logTag, 'Traffic amount to spawn is zero!')
    else
      log('I', logTag, 'Traffic vehicle group is empty')
    end
    ui_message('ui.traffic.spawnLimit', 5, 'traffic', 'traffic')
    return false
  end

  return true
end

local function setupTrafficWaitForUi(usePolice) -- this is called from the radial menu and displays a loading screen
  spawnProcess.amount = -1
  spawnProcess.policeRatio = usePolice and 0.333 or 0
  spawnProcess.waitForUi = true
  setTrafficVars({aiMode = 'traffic', enableRandomEvents = true})
  guihooks.trigger('menuHide')
  guihooks.trigger('app:waiting', true) -- shows the loading icon
end

local function setupCustomTraffic(amount, params) -- spawns a group of vehicles for traffic, with custom parameters
  if type(params) ~= 'table' then params = {} end
  if not amount or amount < 0 then amount = getAmountFromSettings() end
  params.country = params.country or getCountry()

  spawnTraffic(amount, core_multiSpawn.createGroup(amount, params))
end

-- spawns and de-spawns traffic vehicles in freeroam
-- keepInMemory allows instantenous reactivation at the expense of RAM consumption when traffic is disabled
local function toggle(keepInMemory)
  if core_gamestate.state.state == 'freeroam' then
    if state == 'off' then
      setupTraffic()
    elseif state == 'on' then
      if keepInMemory then
        if vars.activeAmount == 0 then
          vars.activeAmount = vars.prevActiveAmount or getAmountFromSettings()
          updateTrafficPool()
        else
          vars.prevActiveAmount = vars.activeAmount
          if vars.prevActiveAmount <= 0 then vars.prevActiveAmount = getAmountFromSettings() end
          vars.activeAmount = 0
          updateTrafficPool()
          for id, veh in pairs(traffic) do
            veh._teleport = true
            veh._teleportDist = 10
          end
        end
      else
        deleteVehicles()
      end
    end
  end
end

local function freezeState() -- stops the traffic, police, and parking systems, and returns the state data
  return M.onSerialize(), gameplay_police.onSerialize(), gameplay_parking.onSerialize()
end

local function unfreezeState(trafficData, policeData, parkingData) -- reverts the traffic and parking systems
  if not trafficData and not parkingData then
    log('I', logTag, 'No traffic or parking data found!')
    return
  end
  if trafficData then
    M.onDeserialized(trafficData)
    scatterTraffic()
  end
  if policeData then
    gameplay_police.onDeserialized(policeData)
  end
  if parkingData then
    gameplay_parking.onDeserialized(parkingData)
  end
end

local function doTraffic(dt, dtSim) -- active traffic logic
  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  local vehCount = 0
  local aiVehsListSize = #trafficAiVehsList
  for i, id in ipairs(trafficIdsSorted) do -- ensures consistent order of vehicles
    vehCount = vehCount + 1
    local veh = traffic[id]
    if veh then
      veh:onUpdate(dt, dtSim)

      if veh.isAi and be:getObjectActive(id) then
        if veh.state == 'reset' then
          veh:onRefresh()

          if vars.enableRandomEvents and vars.aiMode == 'traffic' and veh.respawnCount > 0 then
            veh.role:tryRandomEvent()
          end
        end

        if i == auxiliaryData.queuedVehicle then -- checks one vehicle per frame, as an optimization
          if veh._teleport then
            forceTeleport(id, nil, nil, veh._teleportDist)
          else
            if veh.state == 'active' then
              veh:tryRespawn(aiVehsListSize)
            elseif veh.state == 'queued' then
              processNextSpawn(id)
            end
          end

          veh.otherCollisionFlag = nil -- resets collision flag from previous frame(s)
        end
      end
    end
  end

  auxiliaryData.queuedVehicle = auxiliaryData.queuedVehicle + 1
  if auxiliaryData.queuedVehicle > vehCount then
    auxiliaryData.queuedVehicle = 1
  end

  if vars.spawnValue == 1 or vars.spawnDirBias == 0 then
    auxiliaryData.sampleTimer = auxiliaryData.sampleTimer + dtSim
    if auxiliaryData.sampleTimer > 5 then -- every 5 seconds, sample the current traffic conditions if there is a need to set dynamic spawn parameters
      if vars.spawnValue == 1 then -- adjust global respawn distance based on road network density
        local n1, n2 = map.findClosestRoad(focus.pos)
        if n1 and n2 then
          local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
          if link then
            local branchNodes = map.getGraphpath():getBranchNodesAround(n1, 200)
            local branchNodeCount = branchNodes and #branchNodes or 100
            auxiliaryData.dynamicSpawnDist = (square(link.speedLimit / 2.5) * 4) / branchNodeCount -- distance scattering is affected by the local road network density
          end
        end
      end

      if vars.spawnDirBias == 0 then -- adjust global respawn direction based on current traffic ahead on the road
        local count = 0
        local outboundCount = 0
        for id, veh in pairs(traffic) do
          if veh.state == 'active' then
            count = count + 1
            local dotDir = sign2(focus.dirVec:dot(veh.dirVec))
            if dotDir == 1 then
              outboundCount = outboundCount + 1
            end
          end
        end

        if count == 0 then
          auxiliaryData.dynamicSpawnDir = 0
        else
          local limit = min(1, count / 8) -- stronger effect if there are more vehicles
          auxiliaryData.dynamicSpawnDir = lerp(-limit, limit, outboundCount / count)
        end
      end

      auxiliaryData.sampleTimer = 0
    end
  end
end

local function onSettingsChanged()
  for id, veh in pairs(traffic) do
    if veh.isAi then
      getObjectByID(id).uiState = settings.getValue('trafficMinimap') and 1 or 0
      getObjectByID(id).playerUsable = settings.getValue('trafficEnableSwitching') and true or false
    end
  end
end

local function trackAIAllVeh(mode) -- triggers when the player sets an AI mode for all vehicles
  mode = mode or 'traffic'
  setTrafficVars({aiMode = string.lower(mode)})
end

local function onVehicleMapmgrUpdate(id) -- when the latest spawned vehicle processes its mapmgr, complete the spawning process
  if vehPool and spawnProcess.vehList and spawnProcess.vehList[#spawnProcess.vehList] == id then
    if not auxiliaryData.worldLoaded then
      auxiliaryData.worldLoaded = true
    end

    if spawnProcess.waitForUi then
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
    end
    table.clear(spawnProcess)
    vehPool._updateFlag = true
  end
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == 'autoParking' then
    if not spawnProcess.trafficSetup then
      if spawnProcess.waitForUi then
        guihooks.trigger('app:waiting', false)
        guihooks.trigger('QuickAccessMenu')
      end
      table.clear(spawnProcess)
    end
  end

  if groupName == 'autoTraffic' then
    spawnProcess.vehList = vehList
    activate(spawnProcess.vehList)
  end
end

local function onUpdate(dtReal, dtSim)
  if state == 'loading' then
    spawnTraffic(spawnProcess.amount, spawnProcess.group, spawnProcess.multiSpawnOptions)
  end

  -- these hooks activate the frame after the first or last traffic vehicle gets inserted or removed
  -- this frame delay solves some timing issues
  if state ~= 'on' and trafficAiVehsList[1] then
    extensions.hook('onTrafficStarted')
  end
  if state == 'on' and not trafficAiVehsList[1] then
    extensions.hook('onTrafficStopped')
  end

  if state == 'on' or gameplay_parking.getState() or M.forceFocus then -- always updates focus data while traffic or parking systems are running
    if focus.mode == 'vehicle' then
      focus.vehId = focus.vehId or be:getPlayerVehicleID(0)
      if map.objects[focus.vehId] then
        focus.pos:set(map.objects[focus.vehId].pos)
        focus.dirVec:set(map.objects[focus.vehId].vel) -- uses velocity vector instead of direction vector
        focus.dist = focus.dirVec:length()
        if focus.dist < 1 then
          focus.dirVec:set(map.objects[focus.vehId].dirVec) -- uses direction vector if the vehicle is stationary
        else
          focus.dirVec:setScaled(1 / max(1e-12, focus.dist)) -- normalizes the vector
          focus.dist = min(80, focus.dist) -- capped absolute distance
        end
      end
    end
    if focus.mode == 'camera' or (focus.mode == 'vehicle' and focus.auto and (not map.objects[focus.vehId] or commands.isFreeCamera() or focus.dist < 1)) then
      -- focus.dist < 1 means that the vehicle is stationary; uses the free camera logic to keep traffic vehicles active
      focus.pos:set(core_camera.getPositionXYZ())
      focus.dirVec:set(core_camera.getForwardXYZ())
      if commands.isFreeCamera() then
        focus.dist = 40
      end
    end
  end

  if state == 'on' then
    if vehPool and vehPool._updateFlag and not spawnProcess.vehList then
      updateTrafficPool()
      vehPool._updateFlag = nil
    end

    if be:getEnabled() and not freeroam_bigMapMode.bigMapActive() then
      doTraffic(dtReal, dtSim)
    end
  end
end

local function onPreRender(dt)
  if not M.debugMode then return end

  tempVec:setAdd2(focus.pos, focus.dirVec)
  tempVec.z = tempVec.z - 1
  for id, veh in pairs(traffic) do
    if be:getObjectActive(id) then
      local lineColor = veh.camVisible and debugColors.green or debugColors.white
      local txtColor = debugColors.white
      local bgColor = veh.isPlayerControlled and debugColors.greenAlt or debugColors.blackAlt
      if veh.state == 'fadeIn' then lineColor = debugColors.red end

      if veh.debugLine then
        debugDrawer:drawLine(veh.pos, tempVec, lineColor)
      end

      if veh.debugText then
        debugDrawer:drawTextAdvanced(veh.pos, String('['..veh.id..']: '..math.floor(veh.focusDist)..' m, '..math.floor((veh.speed or 0) * 3.6)..' km/h'), txtColor, true, false, bgColor)
        if veh.pursuit.mode ~= 0 then
          debugDrawer:drawTextAdvanced(veh.pos, String('[PURSUIT]: mode = '..veh.pursuit.mode..', score = '..math.ceil(veh.pursuit.score)..', offenses = '..veh.pursuit.uniqueOffensesCount), txtColor, true, false, bgColor)
        end
      end
    end
  end
end

local function onTrafficStarted()
  setMapData()
  state = 'on'
  auxiliaryData.queuedVehicle = 0
  auxiliaryData.dynamicSpawnDist = 0
  auxiliaryData.dynamicSpawnDir = 0

  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  vehPool._updateFlag = true -- acts like a frame delay for the vehicle pooling system
  focus.auto = true -- this flag is used to enable the focus to change modes

  if gameplay_walk.isWalking() then -- check for player unicycle
    checkPlayer(be:getPlayerVehicleID(0))
  end
  for _, veh in ipairs(getAllVehiclesByType()) do -- check for player vehicles to insert into traffic
    checkPlayer(veh:getId())
  end
end

local function onTrafficStopped()
  deleteTrafficPool()
  table.clear(traffic)
  table.clear(trafficAiVehsList)
  state = 'off'
end

local function onClientStartMission()
  if state == 'off' then
    auxiliaryData.worldLoaded = true
  end
end

local function onClientEndMission()
  onTrafficStopped()
  resetTrafficVars()
  setFocus()
  auxiliaryData.worldLoaded = false
end

local function onUiWaitingState() -- callback for when the waiting UI is shown
  if spawnProcess.waitForUi and not spawnProcess.trafficSetup and not spawnProcess.parkingSetup then
    if settings.getValue('trafficParkedVehicles') then
      spawnProcess.parkingSetup = gameplay_parking.setupVehicles() -- setup parked cars first, if applicable
    else
      spawnProcess.parkingSetup = false
    end
    spawnProcess.trafficSetup = setupTraffic(spawnProcess.amount, spawnProcess.policeRatio)

    if not spawnProcess.trafficSetup and not spawnProcess.parkingSetup then -- if there is nothing to spawn, reset the waiting UI
      table.clear(spawnProcess)
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
      state = 'off'
    end
  end
end

local function onSerialize()
  local trafficData = {}
  for _, veh in pairs(traffic) do
    table.insert(trafficData, veh:onSerialize())
  end
  local data = {state = state, traffic = deepcopy(trafficData), vars = deepcopy(vars)}
  onTrafficStopped()
  mapNodes = nil
  return data
end

local function onDeserialized(data)
  auxiliaryData.worldLoaded = true
  vars = data.vars
  if data.state == 'on' then
    for _, veh in pairs(data.traffic) do
      insertTraffic(veh.id, not veh.isAi)
      if traffic[veh.id] then
        traffic[veh.id]:onDeserialized(veh)
      end
    end
    updateTrafficPool()
  end
end

---- getter functions ----

local function getState() -- returns traffic system state
  return state
end

local function getTrafficPool()
  return core_vehicleActivePooling and core_vehicleActivePooling.getPoolById(vehPoolId) -- returns current vehicle pool object used for traffic
end

local function getTrafficAiVehIds() -- returns traffic list of ids
  return trafficAiVehsList
end

local function getTrafficData() -- returns the full traffic table
  return traffic
end

local function getTrafficVars()
  return vars
end

-- public interface
M.spawnTraffic = spawnTraffic
M.setupTraffic = setupTraffic
M.setupTrafficWaitForUi = setupTrafficWaitForUi
M.setupCustomTraffic = setupCustomTraffic
M.insertTraffic = insertTraffic
M.removeTraffic = removeTraffic
M.deleteVehicles = deleteVehicles
M.activate = activate
M.deactivate = deactivate
M.toggle = toggle
M.refreshVehicles = refreshVehicles

M.getFocus = getFocus
M.setFocus = setFocus
M.forceTeleport = forceTeleport
M.forceTeleportAll = scatterTraffic
M.scatterTraffic = scatterTraffic
M.getRoleConstructor = getRoleConstructor
M.setDebugMode = setDebugMode
M.getTrafficPool = getTrafficPool
M.getTrafficVars = getTrafficVars
M.setTrafficVars = setTrafficVars
M.setActiveAmount = setActiveAmount
M.getIdealSpawnAmount = getIdealSpawnAmount

M.getState = getState
M.freezeState = freezeState
M.unfreezeState = unfreezeState
M.getNumOfTraffic = getNumOfTraffic
M.getTrafficList = getTrafficAiVehIds
M.getTrafficAiVehIds = getTrafficAiVehIds
M.getTrafficData = getTrafficData
M.getTraffic = getTrafficData

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.trackAIAllVeh = trackAIAllVeh
M.onSettingsChanged = onSettingsChanged
M.onVehicleMapmgrUpdate = onVehicleMapmgrUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onUiWaitingState = onUiWaitingState
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M