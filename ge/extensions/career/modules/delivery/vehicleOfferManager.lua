-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"util_stepHandler"}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  step = util_stepHandler
end

-- UI Helper Functions

local function makeTaskLabel(task)
  if task.type == "vehicleDropOff" then
    if task.lookupType == "vehNeedsRepair" or task.lookupType == "vehLargeTruckNeedsRepair" then
      return string.format("Bring to %s for repairs.",dParcelManager.getLocationLabelShort(task.destination))
    end
    if task.lookupType == "vehForPrivate" then
      return string.format("Bring to private home near %s.",dParcelManager.getLocationLabelShort(task.destination))
    end
    if task.lookupType == "vehRepairFinished" then
      return string.format("Repair complete, bring back to %s.",dParcelManager.getLocationLabelShort(task.destination))
    end
    if task.lookupType == "vehLargeTruck" then
      return string.format("Bring to %s.",dParcelManager.getLocationLabelShort(task.destination))
    end
    return string.format("Bring to %s.",dParcelManager.getLocationLabelShort(task.destination))
  elseif task.type == "trailerDropOff" then
    return string.format("Tow to %s.", dParcelManager.getLocationLabelShort(task.destination))
  elseif task.destination then
    return string.format("Drop Off at %s.", dParcelManager.getLocationLabelShort(task.destination))
  else
    return "Unknow Task"
  end
end
M.makeTaskLabel = makeTaskLabel

local vehicleTags = {
  junkerVeh = {
    unlockFlag = "junkerVeh",
    labelPlural = "Junker Cars",
    labelSingular = "Junker Car",
  },
  smallVeh = {
    unlockFlag = "smallVeh",
    labelPlural = "Small Vehicles",
    labelSingular = "Small Vehicle",
  },
  largeVeh = {
    unlockFlag = "largeVeh",
    labelPlural = "Large Vehicles",
    labelSingular = "Large Vehicle",
  },
  fleetVeh = {
    unlockFlag = "fleetVeh",
    labelPlural = "Fleet Cars",
    labelSingular = "Fleet Car",
  },
  exoticVeh = {
    unlockFlag = "exoticVeh",
    labelPlural = "Exotic Cars",
    labelSingular = "Exotic Car",
  },


  emptySmallTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Small Empty Trailers",
    labelSingular = "Small Empty Trailer",
  },
  loadedSmallTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Small Loaded Trailers",
    labelSingular = "Small Loaded Trailer",
  },
  emptyMediumTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Medium Empty Trailers",
    labelSingular = "Medium Empty Trailer",
  },
  loadedMediumTrailers = {
    unlockFlag = "smallTrailersDelivery",
    labelPlural = "Medium Loaded Trailers",
    labelSingular = "Medium Loaded Trailer",
  },
  emptyLargeTrailer = {
    unlockFlag = "largeTrailersDelivery",
    labelPlural = "Large Empty Trailers",
    labelSingular = "Large Empty Trailer",
  },
  loadedLargeTrailers = {
    unlockFlag = "largeTrailersDelivery",
    labelPlural = "Large Loaded Trailers",
    labelSingular = "Large Loaded Trailer",
  }
}

local skillIcons = {
  delivery = "boxPickUp03",
  vehicleDelivery = "keys1"
}
local function isVehicleTagUnlocked(tag)
  if not vehicleTags[tag] then return true end
  if not vehicleTags[tag].unlockFlag then return true end

  local unlocked = career_modules_unlockFlags.getFlag(vehicleTags[tag].unlockFlag)
  local flagDefinition = career_modules_unlockFlags.getFlagDefinition(vehicleTags[tag].unlockFlag)

  return unlocked, flagDefinition
end

M.isVehicleTagUnlocked = isVehicleTagUnlocked
local function getVehicleTagUnlockedSimple()
  local status = {}
  for tag, info in pairs(vehicleTags) do
    status[tag] = isVehicleTagUnlocked(tag)
  end
  return status
end
M.getVehicleTagUnlockedSimple = getVehicleTagUnlockedSimple

local function getVehicleTagLabelSingular(tag)
  if not vehicleTags[tag] then return "No Category" end
  return vehicleTags[tag].labelSingular
end
M.getVehicleTagLabelSingular = getVehicleTagLabelSingular
local function getVehicleTagLabelPlural(tag)
  if not vehicleTags[tag] then return "No Category" end
  return vehicleTags[tag].labelPlural
end
M.getVehicleTagLabelPlural = getVehicleTagLabelPlural

local function getDefaultVehicleModifiersForUI()
  return {
    {type = "route", icon = "routeSimple", active = true, label = "Responsible", description = "Bonus rewards if you stay on route and dont waste time.", important = true},
    {type = "damage", icon = "cogsDamaged", active = true, label = "Careful", description = "Large penalty if vehicle is damaged.", important = true}
  }
end
M.getDefaultVehicleModifiersForUI = getDefaultVehicleModifiersForUI


--[[
local function onGetSkillUnlockInfoForUi(skill, unlocks)
  -- vehicles
  if skill.id == "vehicleDelivery" then
    local tagsByTier = {}
    for key, info in pairs(vehicleTags) do
      local tier = 1
      if info.requirements then
        tier = info.requirements.vehicleDelivery
      end
      if info.requirements.vehicleDelivery then
        tagsByTier[tier] = tagsByTier[tier] or {}
        table.insert(tagsByTier[tier], info.labelPlural)
      end
    end
    for tier, list in pairs(tagsByTier) do
      table.sort(list)
      unlocks[tier] = unlocks[tier] or {}
      for _, value in ipairs(list) do
        table.insert(unlocks[tier], {type="text", label = value})
      end
    end
  end

  -- trailers
  if skill.id == "delivery" then
    local tagsByTier = {}
    for key, info in pairs(vehicleTags) do
      local tier = 1
      if info.requirements then
        tier = info.requirements.delivery
      end
      if info.requirements.delivery then
        tagsByTier[tier] = tagsByTier[tier] or {}
        table.insert(tagsByTier[tier], info.labelPlural)
      end
    end
    for tier, list in pairs(tagsByTier) do
      table.sort(list)
      unlocks[tier] = unlocks[tier] or {}
      for _, value in ipairs(list) do
        table.insert(unlocks[tier], {type="text", label = value})
      end
    end
  end
end

M.onGetSkillUnlockInfoForUi = onGetSkillUnlockInfoForUi
]]

----------------------
-- Offer Management --
----------------------

local allOffers = {}

local function addOffer(offer)
  table.insert(allOffers, offer)
end

local function sameLocationOffer(offer, otherLoc)
  return M.sameLocation(offer.origin, otherLoc)
end

local function sameLocation(a,b)
  local same = true
  for k, v in pairs(a) do
    same = same and a[k] == b[k]
  end
  return same
end

local function getAllOfferCustomFilter(filter, ...)
  career_modules_delivery_generator.triggerAllGenerators()
  local ret = {}
  for _, offer in ipairs(allOffers) do
    if filter(offer, ...) then
      table.insert(ret, offer)
    end
  end
  return ret
end

local function getAllOfferForLocation(loc)
  return M.getAllOfferCustomFilter(M.sameLocationOffer, loc)
end

local function getAllOfferUnexpired()
  career_modules_delivery_generator.triggerAllGenerators()
  local ret = {}
  for _, offer in ipairs(allOffers) do
    if offer.offerExpiresAt > dGeneral.time()
       and not offer.spawned
      then
      table.insert(ret, offer)
    end
  end
  return ret
end

local function getAllOfferAtFacilityUnexpired(facId, psPath)
  career_modules_delivery_generator.triggerAllGenerators()
  local ret = {}
  for _, offer in ipairs(allOffers) do
    if    offer.origin.facId == facId
      and offer.offerExpiresAt > dGeneral.time()
      and not offer.spawned
      --and dProgress.isFacilityVisible(offer.task.destination.facId)
      --and dProgress.isFacilityUnlocked(offer.task.destination.facId)
       then
      table.insert(ret, offer)
    end
  end
  return ret
end

-- Offer Spawning

local function getOfferById(id)
  for _, offer in ipairs(allOffers) do
    if offer.id == id then
      return offer
    end
  end
  return nil
end

local function spawnOffer(offerId, fadeToBlack, callback)
  local offer = getOfferById(offerId)
  if not offer then log("E","","Could not find offer with it "..dumps(offerId)) return end
  log("I","","Spawning offer " .. offerId)
  offer.spawned = true
  if fadeToBlack == nil then fadeToBlack = true end
  local vehId = nil
  local options = {
    model = offer.vehicle.model,
    config = offer.vehicle.config,
    autoEnterVehicle = false,
  }
  local sequence = {
    step.makeStepSpawnVehicle(options, function(_, id)
      vehId = id end),
    step.makeStepReturnTrueFunction(function()
      -- move vehicle to right spot
      local ps = dGenerator.getParkingSpotByPath(offer.spawnLocation.psPath)
      ps:moveResetVehicleTo(vehId, nil, false, nil, nil, true)
      -- setup mileage
      local veh = getObjectByID(vehId)
      local mileage = offer.vehicle.mileage or 0
      offer.vehicle.vehId = vehId
      veh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, career_modules_vehicleShopping.getVisualValueFromMileage(mileage)))
      -- turn vehicle off
      core_vehicleBridge.executeAction(veh,'setIgnitionLevel', 0)
      gameplay_rawPois.clear()
      return true
    end),
    step.makeStepReturnTrueFunction(function(step)
      if not step.sentCommand then
        step.sentCommand = true
        local veh = getObjectByID(vehId)
        core_vehicleBridge.requestValue(veh, function(res)
          step.pingComplete = true
        end, 'ping')
      end
      return step.pingComplete or false
    end),
    step.makeStepReturnTrueFunction(function(step)
      if not step.sentCommand then
        step.sentCommand = true
        local vehData = core_vehicle_manager.getVehicleData(vehId)
        local veh = getObjectByID(vehId)
        core_vehicleBridge.requestValue(veh, function(res)
          step.odometerComplete = true
          local mainPartName = "/" .. vehData.config.mainPartName
          local part = res.result[mainPartName]
          if not part then
            log("W","","Could not find part "..dumps(mainPartName) .." - starting odometer will be -1")
            offer.startingOdometer = -1
          else
            offer.startingOdometer = part.odometer
          end
        end, 'getPartConditions')
      end
      return step.odometerComplete or false
    end),
    step.makeStepReturnTrueFunction(function()
      if gameplay_walk.isWalking() then
        local veh = getObjectByID(vehId)
        gameplay_walk.setRot(veh:getPosition() - getPlayerVehicle(0):getPosition())
      end

      --career_modules_vehicleDeletionService.flagForDeletion(vehId)
      dVehicleTasks.addVehicleTask(vehId, offer)
      dGeneral.startDeliveryMode()
      return true
    end),
    step.makeStepReturnTrueFunction(function()
      guihooks.trigger("updateCargoData")
      return true
    end),

    step.makeStepReturnTrueFunction(function()
      local veh = getObjectByID(vehId)
      local camDir = veh:getPosition() - getPlayerVehicle(0):getPosition()
      if gameplay_walk.isWalking() then
        gameplay_walk.setRot(camDir)
      end
      return true
    end)
   }

   if fadeToBlack then
    table.insert(sequence, 1, step.makeStepFadeToBlack(0.4))
    table.insert(sequence, 1, step.makeStepWait(0.15))
    table.insert(sequence, step.makeStepFadeFromBlack(0.4))
   end

   step.startStepSequence(sequence, callback)
end
M.spawnOffer = spawnOffer


--[[
local function onBranchTierReached(skill, tier)
  if skill == "vehicleDelivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSkill('vehicleDelivery', tier-1), dProgress.getMoneyMultiplerForSkill('vehicleDelivery', tier)
    log("I","",string.format("Reached tier %d of vehicle delivery. Increasing money rewards from %0.2f to %0.2f", tier, prevMult, nextMult))
    for _, offer in ipairs(allOffers) do
      if offer.data.type == "vehicle" and  offer.rewards and offer.rewards.money then
        offer.rewards.money = offer.rewards.money / prevMult * nextMult
      end
    end
  end
  if skill == "delivery" then
    local prevMult, nextMult = dProgress.getMoneyMultiplerForSkill('delivery', tier-1), dProgress.getMoneyMultiplerForSkill('delivery', tier)
    log("I","",string.format("Reached tier %d of delivery. Increasing money rewards from %0.2f to %0.2f", tier, prevMult, nextMult))
    for _, offer in ipairs(allOffers) do
      if offer.data.type == "trailer" and  offer.rewards and offer.rewards.money then
        offer.rewards.money = offer.rewards.money / prevMult * nextMult
      end
    end
  end
end
M.onBranchTierReached = onBranchTierReached
--]]

M.addOffer = addOffer
M.getOfferById = getOfferById
M.sameLocationOffer = sameLocationOffer
M.sameLocation = sameLocation
M.getAllOfferCustomFilter = getAllOfferCustomFilter
M.getAllOfferUnexpired = getAllOfferUnexpired
M.getAllOfferForLocation = getAllOfferForLocation
M.getAllOfferAtFacilityUnexpired = getAllOfferAtFacilityUnexpired

return M