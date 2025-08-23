-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local E = setmetatable({}, {__newindex = function(t, key, val) log('E', 'ai.lua', 'Tried to insert new elements into token empty table') end})

M.mode = 'disabled' -- this is the main mode
M.manualTargetName = nil
M.debugMode = 'off'
M.speedMode = nil
M.routeSpeed = nil
M.extAggression = 0.3
M.cutOffDrivability = 0
M.driveInLaneFlag = 'off'
M.extAvoidCars = 'auto'

-- [[ STORE FREQUENTLY USED FUNCTIONS IN UPVALUES ]] --
local buffer = require("string.buffer")
local max = math.max
local min = math.min
local sin = math.sin
local asin = math.asin
local pi = math.pi
local abs = math.abs
local sqrt = math.sqrt
local floor = math.floor
local tableInsert = table.insert
local tableRemove = table.remove
local tableConcat = table.concat
local strFormat = string.format

-- [[ HEAVY DEBUG MODE ]] --
local visDebug = {trajecRec = {last = 0}, routeRec = {last = 0}, labelRenderDistance = 10, debugSpots = {}, candidatePaths = nil}
--local newPositionsDebug = {} -- for debug purposes

-- [[ Simulation time step]] --
local dt

-- [[ ENVIRONMENT VARIABLES ]] --
local g = obj:getGravity() -- standard gravity is negative
local gravityDir = vec3(0, 0, sign2(g))
g = max(1e-30, abs(g)) -- prevent divivion by 0 gravity

-- [[ PERFORMANCE RELATED ]] --
local aggression = 1

-- [[ AI DATA: POSITION, CONTROL, STATE ]] --
local ai = {
  pos = obj:getFrontPosition(),
  dirVec = obj:getDirectionVector(),
  prevDirVec = obj:getDirectionVector(),
  upVec = obj:getDirectionVectorUp(),
  rightVec = vec3(),
  width = nil,
  length = nil,
  wheelBase = nil,
  currentSegment = {},
  vel = vec3(obj:getSmoothRefVelocityXYZ()),
  speed = vec3(obj:getSmoothRefVelocityXYZ()):length(),
  staticFrictionCoef = 1,
  ghostR = nil,
  ghostL = nil,
}

local targetSpeedDifSmoother = newTemporalSmoothingNonLinear(1e300, 4, 0)
local targetSpeedSmoother = newTemporalSmoothingNonLinear(10, 10, ai.speed)
local aiDeviationSmoother = newTemporalSmoothing(1)
local smoothTcs = newTemporalSmoothingNonLinear(0.1, 0.9)
local throttleSmoother = newTemporalSmoothing(1e30, 0.2)

local internalState = {
  changePlanTimer = 0,
  aiCannotMoveTime = 0,
  aiForceGoFrontTime = 0,
  road = 'onroad',
  crash = {time = 0, manoeuvre = 0, dir = nil, pos = nil},
  chaseData = {playerState = nil, playerStoppedTimer = 0, playerRoad = nil, driveAhead = false, targetSpeed = nil}
}

local twt = {
  state = 0,
  dirState = {0, 0}, -- direction, steer
  posTable = {vec3(), vec3(), vec3(), vec3()},
  dirTable = {vec3(), vec3(), vec3(), vec3()},
  minRay = "",
  rayMins = {math.huge, math.huge, math.huge, math.huge, math.huge, math.huge, math.huge, math.huge}, --clockwise beginning from corner front left
  minRayCoefs = {0, 0, 0, 0, 0, 0, 0, 0}, -- clockwise as above
  blueNoiseCoefs = {0, 0, 0, 0, 0, 0, 0, 0},
  biasedCoefs = {0, 0, 0, 0, 0, 0, 0, 0},
  blueNoiseRR = 0,
  sampleCounter = 0, -- for starting scan, to give some time for precision
  targetSpeed = 0,
  OBBinRange = {},
  RRT = {1,1,1,2,1,2,2,2,2,2,2,3,2,3,3,3,3,3,3,4,3,4,4,4,4,4,4,1,4,1,1,1},
  speedSmoother = newTemporalSmoothingNonLinear(1000, 0.25),
  steerSmoother = newTemporalSmoothingNonLinear(2)
}

twt.reset = function()
  twt.state = 0
  twt.dirState[1], twt.dirState[2] = 0, 0
  twt.minRay = nil
  for i = 1, #twt.rayMins do twt.rayMins[i] = math.huge end
  for i = 1, #twt.blueNoiseCoefs do twt.blueNoiseCoefs[i] = 0 end
  twt.sampleCounter = 0
  twt.targetSpeed = 0
  twt.speedSmoother:set(0)
  twt.steerSmoother:set(0)
end

local forces = {}
local velocities = {}
local lastCommand = {steering = 0, throttle = 0, brake = 0, parkingbrake = 0}

local opt = {driveInLaneFlag = false, racing = false, trajMethod = nil, aggressionMode = nil, avoidCars = 'on'}

-- [[ TRAFFIC ]] --
local trafficStates = {}
local trafficPathState = {}

local traffic = {
  trafficTable = {},
  trafficFilterQue = {array = {}, dict = {}},
  trafficFilterFromQue = {},
  frameQue = 0,
  rateQue = 0, -- 1 means adding a que vehicle every second
  filtered = true,    -- TrafficFilter on or off (true/false)
  intersection = true, -- check for intersection between ai and other vehicle
  vdraw = false,       -- draw debuf spheres to show traffic vehicles in trafficTable
  Rfl = 60, -- larger radius for traffic filter queue
  Rfl_fun = function(v) return clamp((v+10)*3, 60, 200) end, --
  Rfs = 60, -- smaller radius for traffic table
  Rfs_fun = function(v) return clamp(v*3, 60, 100) end,
  distAhead = 40     -- minimum Ahead distance for searching traffic vehicle
}

-- [[ OPPONENT DATA ]] --
local player

-- [[ SETTINGS, PARAMETERS, AUXILIARY DATA ]] --
local mapData -- map data including node connections (edges and edge data), node positions and node radii
local signalsData -- traffic intersection and signals data
local currentRoute
local MIN_PLAN_COUNT = 3
local targetWPName
local edgeDict
local wpList
local manualPath
local validateInput = nop
local speedProfile
local loopPath, noOfLaps
local parameters
local restoreGearboxMode = false
local targetObjectSelectionMode
local scriptData
local scriptai = nil
local recover = {recoverOnCrash = false, recoverTimer = 0, _recoverOnCrash = false}
------------------------------

-- For Debugging (useful function to print a numbered list of upvalues of a specific function)
local function inspect_upvalues(func)
  local i = 1
  while true do
    local name, value = debug.getupvalue(func, i)
    if not name then break end
    print(string.format("Upvalue %d: %s = %s", i, name, tostring(value)))
    i = i + 1
  end
end

local dataLogger = {logData = nop}
local function logDataTocsv()
  if not dataLogger.csvFile then
    print('Started Logging Data')
    dataLogger.csvFile = require('csvlib').newCSV("time", "posX", "posY", "posZ", "speed", "targetSpeed", "ax", "ay", "az", "vx", "vy", "vz", "throttle", "brake", "steering", "staticFrictionCoef")
    dataLogger.time = 0
  else
    dataLogger.time = dataLogger.time + dt
  end
  dataLogger.csvFile:add(
    dataLogger.time,
    ai.pos.x,
    ai.pos.y,
    ai.pos.z,
    ai.speed,
    ((currentRoute or E).plan or E).targetSpeed,
    -sensors.gy,
    sensors.gx,
    sensors.gz,
    ai.vel:dot(ai.dirVec),
    -(ai.vel:dot(ai.rightVec)),
    ai.vel:dot(ai.upVec),
    lastCommand.throttle,
    lastCommand.brake,
    lastCommand.steering,
    ai.staticFrictionCoef)
end

local function writeCsvFile(name)
  if dataLogger.csvFile then
    print('Writing Data to CSV.')
    dataLogger.csvFile:write(name)
    dataLogger.csvFile = nil
    dataLogger.time = nil
    print('Done')
  else
    print('No data to write')
  end
end

local function startStopDataLog(name)
  if dataLogger.logData == nop then
    print('Initialized Data Log')
    dataLogger.logData = logDataTocsv
    dataLogger.name = name
  else
    print('Stopped Logging Data')
    dataLogger.logData = nop
    writeCsvFile(dataLogger.name or name)
    dataLogger.name = nil
  end
end

local function getObjectBoundingBox(id)
  local x = obj:getObjectDirectionVector(id)
  local z = obj:getObjectDirectionVectorUp(id)
  local y = z:cross(x)
  y:setScaled(obj:getObjectInitialWidth(id) * 0.5 / max(y:length(), 1e-30))
  x:setScaled(obj:getObjectInitialLength(id) * 0.5)
  z:setScaled(obj:getObjectInitialHeight(id) * 0.5)
  return obj:getObjectCenterPosition(id), x, y, z
end

local function drawOBB(c, x, y, z, col)
  -- c: center point
  -- x: front half extent vec
  -- y: left half extent vec
  -- z: up half extent vec

  local debugDrawer = obj.debugDrawProxy
  col = col or color(255, 0, 0, 255)

  local p1 = c - x + y - z -- RLD
  local p2 = c - x - y - z -- RRD
  local p3 = c - x - y + z -- RRU
  local p4 = c - x + y + z -- RLU
  local p5 = c + x + y - z -- FLD
  local p6 = c + x - y - z -- FRD
  local p7 = c + x - y + z -- FRU
  local p8 = c + x + y + z -- FLU

  -- rear face
  debugDrawer:drawCylinder(p1, p2, 0.02, col)
  debugDrawer:drawCylinder(p2, p3, 0.02, col)
  debugDrawer:drawCylinder(p3, p4, 0.02, col)
  debugDrawer:drawCylinder(p4, p1, 0.02, col)

  -- front face
  debugDrawer:drawCylinder(p5, p6, 0.02, col)
  debugDrawer:drawCylinder(p6, p7, 0.02, col)
  debugDrawer:drawCylinder(p7, p8, 0.02, col)
  debugDrawer:drawCylinder(p8, p5, 0.02, col)

  -- left face
  debugDrawer:drawCylinder(p1, p5, 0.02, col)
  debugDrawer:drawCylinder(p4, p8, 0.02, col)

  -- right face
  debugDrawer:drawCylinder(p2, p6, 0.02, col)
  debugDrawer:drawCylinder(p3, p7, 0.02, col)
end

local function drawVehicleBoundingBox(vid, col)
  local c, vx, vy, vz = getObjectBoundingBox(vid)
  drawOBB(c, vx, vy, vz, col)
end

local function aistatus(status, category)
  guihooks.trigger("AIStatusChange", {status=status, category=category})
end

local function getState()
  return M
end

local function stateChanged()
  if playerInfo.anyPlayerSeated then
    guihooks.trigger("AIStateChange", getState())
  end
end

local function setSpeed(speed)
  if type(speed) ~= 'number' then M.routeSpeed = nil else M.routeSpeed = speed end
end

local function setSpeedMode(speedMode)
  if speedMode == 'set' or speedMode == 'limit' or speedMode == 'legal' or speedMode == 'off' then
    M.speedMode = speedMode
  else
    M.speedMode = nil
  end
end

local function resetSpeedModeAndValue()
  M.speedMode = nil -- maybe this should be 'off'
  M.routeSpeed = nil
end

local function setAggressionInternal(v)
  aggression = v or M.extAggression
end

local function setAggressionExternal(v)
  M.extAggression = v or M.extAggression
  setAggressionInternal()
  stateChanged()
end

local function setAggressionMode(aggrmode)
  if aggrmode == 'rubberBand' then
    opt.aggressionMode = aggrmode
  else
    opt.aggressionMode = nil
    setAggressionInternal()
  end
end

local function resetAggression()
  setAggressionInternal()
end

local function resetInternalStates()
  trafficStates.block = {timer = 0, coef = 0, timerLimit = 6, block = false}
  trafficStates.side = {timer = 0, cTimer = 0, side = 1, displacement = 0, timerLimit = 6}
  trafficStates.action = {hornTimer = -1, hornTimerLimit = 1, forcedStop = false}
  trafficStates.intersection = {timer = 0, turn = 0, block = false}

  internalState.chaseData.playerState = nil
  internalState.chaseData.playerStoppedTimer = 0
  internalState.chaseData.playerRoad = nil
  internalState.chaseData.driveAhead = false
  internalState.chaseData.targetSpeed = nil

  internalState.crash.time = 0
  internalState.crash.manoeuvre = 0
  internalState.crash.dir = nil
  internalState.crash.pos = nil

  if electrics.values.horn == 1 then electrics.horn(false) end
  if electrics.values.signal_left_input or electrics.values.signal_right_input then electrics.set_warn_signal(false) end

  trafficPathState = {}
end
resetInternalStates()

local function resetParameters()
  -- parameters are used for finer AI control
  parameters = {
    turnForceCoef = 2, -- coefficient for curve spring forces
    awarenessForceCoef = 0.25, -- coefficient for vehicle awareness displacement
    edgeDist = 0, -- minimum distance from the edge of the road
    trafficWaitTime = 2, -- traffic delay after stopping at intersection
    delayFactorWaitTime = {0.55 + (0.95 - 0.55) * math.random() , 0.05 + (0.45 - 0.05) * math.random()},
    enableElectrics = true, -- allows the ai to automatically use electrics such as hazard lights (especially for traffic)
    driveStyle = 'default',
    staticFrictionCoefMult = 0.95,
    lookAheadKv = 0.6,
    applyWidthMarginOffset = true,
    planErrorSmoothing = true,
    springForceIntegratorDispLim = 0.1, -- node displacement force magnitude limit
    understeerThrottleControl = 'on', -- anything other than an 'off' value will keep this active
    oversteerThrottleControl = 'on', -- anything other than an 'off' value will keep this active
    throttleTcs = 'on', -- anything other than an 'off' value will keep this active
    abBrakeControl = 'on',
    underSteerBrakeControl = 'on',
    throttleKp = 0.5,
    targetSpeedSmootherRate = 10,
  }
end
resetParameters()

local function setParameters(data)
  tableMerge(parameters, data)
end

local function dumpParameters()
  dump(parameters)
  dump('aggression = ', aggression)
end
M.dumpParameters = dumpParameters

local function setTargetObjectID(id)
  M.targetObjectID = M.targetObjectID ~= objectId and id or -1
  if M.targetObjectID ~= -1 then targetObjectSelectionMode = 'manual' end
end

local function calculateWheelBase()
  local avgWheelNodePos, numOfWheels = vec3(), 0
  for _, wheel in pairs(wheels.wheels) do
    -- obj:getNodePosition is the pos vector of query node (wheel.node1) relative to ref node in world coordinates
    avgWheelNodePos:setAdd(obj:getNodePosition(wheel.node1))
    numOfWheels = numOfWheels + 1
  end
  if numOfWheels == 0 then return 0 end

  avgWheelNodePos:setScaled(1 / numOfWheels)

  local dirVec = obj:getDirectionVector()
  local avgFrontWheelPos, frontWheelCount = vec3(), 0
  local avgBackWheelPos, backWheelCount = vec3(), 0
  for _, wheel in pairs(wheels.wheels) do
    local wheelPos = obj:getNodePosition(wheel.node1)
    if wheelPos:dot(dirVec) > avgWheelNodePos:dot(dirVec) then
      avgFrontWheelPos:setAdd(wheelPos)
      frontWheelCount = frontWheelCount + 1
    else
      avgBackWheelPos:setAdd(wheelPos)
      backWheelCount = backWheelCount + 1
    end
  end

  avgFrontWheelPos:setScaled(1 / frontWheelCount)
  avgBackWheelPos:setScaled(1 / backWheelCount)

  return avgFrontWheelPos:distance(avgBackWheelPos)
end

local function updatePlayerData()
  mapmgr.getObjects()
  if not next(mapmgr.objects) then return end -- prevents changes if table is empty

  if mapmgr.objects[M.targetObjectID] and targetObjectSelectionMode == 'manual' then
    player = mapmgr.objects[M.targetObjectID]
  elseif tableSize(mapmgr.objects) == 2 then
    if player ~= nil then
      player = mapmgr.objects[player.id]
    else
      for k, v in pairs(mapmgr.objects) do
        if k ~= objectId then
          M.targetObjectID = k
          player = v
          break
        end
      end
      targetObjectSelectionMode = 'auto'
    end
  else
    if player ~= nil and player.active == true then
      player = mapmgr.objects[player.id]
    else
      for k, v in pairs(mapmgr.objects) do
        if k ~= objectId and v.active == true then
          M.targetObjectID = k
          player = v
          break
        end
      end
      targetObjectSelectionMode = 'targetActive'
    end
  end
end

local function driveCar(steering, throttle, brake, parkingbrake)
  input.event("steering", steering, "FILTER_AI", nil, nil, nil, "ai")
  input.event("throttle", throttle, "FILTER_AI", nil, nil, nil, "ai")
  input.event("brake", brake, "FILTER_AI", nil, nil, nil, "ai")
  input.event("parkingbrake", parkingbrake, "FILTER_AI", nil, nil, nil, "ai")

  lastCommand.steering = steering
  lastCommand.throttle = throttle
  lastCommand.brake = brake
  lastCommand.parkingbrake = parkingbrake
end

local function populateOBBinRange(range)
  range = range * range
  local i = 0
  for id in pairs(mapmgr.getObjects()) do
    if id ~= objectId then
      local pos = obj:getObjectCenterPosition(id)
      if pos:squaredDistance(ai.pos) < range then
        twt.OBBinRange[i+1] = pos

        -- Get bounding box direction vectors
        twt.OBBinRange[i+2] = obj:getObjectDirectionVector(id) -- x
        twt.OBBinRange[i+4] = obj:getObjectDirectionVectorUp(id) -- z
        twt.OBBinRange[i+3] = twt.OBBinRange[i+3] or vec3()
        twt.OBBinRange[i+3]:setCross(twt.OBBinRange[i+4], twt.OBBinRange[i+2]); twt.OBBinRange[i+3]:normalize() -- y (left)

        -- Scale bounding box direction vectors to vehicle diamensions
        twt.OBBinRange[i+3]:setScaled(obj:getObjectInitialWidth(id) * 0.5)
        twt.OBBinRange[i+2]:setScaled(obj:getObjectInitialLength(id) * 0.5)
        twt.OBBinRange[i+4]:setScaled(obj:getObjectInitialHeight(id) * 0.5)
        i = i + 4
      end
    end
  end
  twt.OBBinRange.n = i
end

local function castRay(rpos, rdir, rayDist)
  for i = 1, twt.OBBinRange.n, 4 do
    local minHit, maxHit = intersectsRay_OBB(rpos, rdir, twt.OBBinRange[i], twt.OBBinRange[i+1], twt.OBBinRange[i+2], twt.OBBinRange[i+3])
    if maxHit > 0 then
      rayDist = min(rayDist, max(minHit, 0))
    end
  end
  return obj:castRayStatic(rpos, rdir, rayDist)
end

local function driveToTarget(targetPos, throttle, brake, targetSpeed)
  if not targetPos then return end

  local plan = currentRoute and currentRoute.plan
  targetSpeed = targetSpeed or plan and plan.targetSpeed
  if not targetSpeed then return end

  local targetVec = targetPos - ai.pos; targetVec:normalize()
  local dirAngle = asin(ai.rightVec:dot(targetVec))

  -- oversteer
  local throttleOverCoef = 1
  if ai.speed > 1 then
    local rightVel = ai.rightVec:dot(ai.vel)
    if rightVel * ai.rightVec:dot(targetPos - ai.pos) > 0 then
      local rotVel = min(1, (ai.prevDirVec:projectToOriginPlane(ai.upVec):normalized()):distance(ai.dirVec) * dt * 10000)
      throttleOverCoef = max(0, 1 - abs(rightVel * ai.speed * 0.05) * min(1, dirAngle * dirAngle * ai.speed * 6) * rotVel)
    end
  end

  local dirVel = ai.vel:dot(ai.dirVec)
  local absAiSpeed = abs(dirVel)
  local throttleUnderCoef = 1
  local brakeUnderCoef = 1

  if plan and plan[3] and dirVel > 3 then
    local p1, p2 = plan[1].pos, plan[2].pos
    local p2p1DirVec = p2 - p1; p2p1DirVec:normalize()

    local tp2 = (plan.targetSeg or 0) > 1 and targetPos or plan[3].pos
    local targetSide = (tp2 - p2):dot(p2p1DirVec:cross(ai.upVec))

    local outDeviation = aiDeviationSmoother:value() - plan.aiDeviation * sign(targetSide)
    outDeviation = sign(outDeviation) * min(1, abs(outDeviation))
    aiDeviationSmoother:set(outDeviation)
    aiDeviationSmoother:getUncapped(0, dt)

    if outDeviation > 0 and absAiSpeed > 3 then
      local steerCoef = outDeviation * absAiSpeed * absAiSpeed * min(1, dirAngle * dirAngle * 4)
      local understeerCoef = max(0, steerCoef) * min(1, abs(ai.vel:dot(p2p1DirVec) * 3))
      local noUndersteerCoef = max(0, 1 - understeerCoef)
      throttleUnderCoef = noUndersteerCoef
      brakeUnderCoef = min(brakeUnderCoef, max(0, 1 - understeerCoef * understeerCoef))
    end
  else
    aiDeviationSmoother:set(0)
  end

  -- wheel speed
  local throttleTcsCoef = 1
  local brakeABSCoef = 1
  if absAiSpeed > 0.05 then
    if sensors.gz <= 0.1 then
      local totalSlip = 0
      local propSlip = 0
      local totalDownForce = 0
      local lwheels = wheels.wheels
      for i = 0, tableSizeC(lwheels) - 1 do
        local wd = lwheels[i]
        if not wd.isBroken then
          local lastSlip = wd.lastSlip
          local downForce = wd.downForceRaw
          totalSlip = totalSlip + lastSlip * downForce
          totalDownForce = totalDownForce + downForce
          if wd.isPropulsed then
            propSlip = max(propSlip, lastSlip)
          end
        end
      end

      absAiSpeed = max(absAiSpeed, 3)

      totalSlip = totalSlip / (totalDownForce + 1e-25)

      -- abs
      brakeABSCoef = min(1, 1.5 * square(square(square(max(0, absAiSpeed - totalSlip) / absAiSpeed))))

      -- tcs
      propSlip = propSlip * (parameters.driveStyle == 'offRoad' and 0.8 or 1)
      local tcsCoef = max(0, absAiSpeed - propSlip * propSlip) / absAiSpeed
      throttleTcsCoef = min(tcsCoef, smoothTcs:get(tcsCoef, dt))
    else
      brakeABSCoef = 0
      throttleTcsCoef = 0
    end
  end

  local brakeCoef = 1
  if parameters.underSteerBrakeControl ~= 'off' then
    brakeCoef = min(brakeCoef, brakeUnderCoef)
  end
  if parameters.abBrakeControl ~= 'off' then
    brakeCoef = min(brakeCoef, brakeABSCoef)
  end

  local throttleCoef = 1
  if parameters.oversteerThrottleControl ~= 'off' then
    throttleCoef = min(throttleCoef, throttleOverCoef)
  end
  if parameters.understeerThrottleControl ~= 'off' then
    throttleCoef = min(throttleCoef, throttleUnderCoef)
  end
  if parameters.throttleTcs ~= 'off' then
    throttleCoef = min(throttleCoef, throttleTcsCoef)
  end

  local dirTarget = ai.dirVec:dot(targetVec)
  local dirTargetAxis = ai.rightVec:dot(targetVec)

  if internalState.crash.manoeuvre == 1 and dirTarget < ai.dirVec:dot(internalState.crash.dir) then
    driveCar(-sign(dirAngle), brake * brakeCoef, throttle * throttleCoef, 0)
    return
  else
    internalState.crash.manoeuvre = 0
  end

  if parameters.driveStyle == 'offRoad' then
    brakeCoef = 1
    throttleCoef = sqrt(throttleCoef)
  end

  internalState.aiForceGoFrontTime = max(0, internalState.aiForceGoFrontTime - dt)
  if twt.state == 1 and internalState.aiCannotMoveTime > 1 and internalState.aiForceGoFrontTime == 0 then
    twt.state = 0
    internalState.aiCannotMoveTime = 0
    internalState.aiForceGoFrontTime = 2
  end

  if internalState.aiForceGoFrontTime > 0 and dirTarget < 0 then
    dirTarget = -dirTarget
    dirAngle = -dirAngle
  end

  if currentRoute and (dirTarget < 0 or (twt.state == 1 and dirTarget < 0.866)) then   -- TODO: Improve entry condition when twt.state == 1
    local helperVec = 0.35 * ai.upVec -- auxiliary vector
    twt.posTable[2]:setAdd2(ai.pos, helperVec)
    helperVec:setScaled2(ai.dirVec, -0.05 * ai.length)
    twt.posTable[2]:setAdd(helperVec)
    helperVec:setScaled2(ai.rightVec, 0.5 * (0.7 * ai.width)) -- lateral translation
    twt.posTable[2]:setAdd(helperVec) -- front right corner pos
    helperVec:setScaled(-2)
    twt.posTable[1]:setAdd2(twt.posTable[2], helperVec) -- front left corner pos
    helperVec:setScaled2(ai.dirVec, -0.9 * ai.length) -- longitudinal translation
    twt.posTable[3]:setAdd2(twt.posTable[2], helperVec) -- back right corner pos
    twt.posTable[4]:setAdd2(twt.posTable[1], helperVec) -- back left corner pos

    twt.dirTable[1]:setScaled2(ai.rightVec, -1)
    twt.dirTable[2]:set(ai.dirVec)
    twt.dirTable[3]:set(ai.rightVec)
    twt.dirTable[4]:setScaled2(ai.dirVec, -1)

    local sizeRatio = ai.length/ai.width
    local blueNoiseRange = 6 + 2 * sizeRatio
    local rayDist = 4 * ai.wheelBase -- TODO: Optimize rayDist. Higher is better for more open spaces but w performance hit
    populateOBBinRange(rayDist)
    local tmpVec = vec3()
    local RRPicks = max(1, min(floor(150 * dt + 0.5), 8)) -- x * dt where x/fps is the numer of samples
    for k = 1, RRPicks do --the ray cast loop: each iteration scans one area and casts on the minimum
      local i = 0
      local blueIndex = twt.blueNoiseRR * blueNoiseRange
      if blueIndex < 3 then
        i = floor(1 + blueIndex)
      elseif blueIndex < 6 then
        i = floor(1 + blueIndex) + 1
      elseif blueIndex < 6 + sizeRatio then
        i = 4
      else
        i = 8
      end

      local j = i * 4
      tmpVec:setLerp(twt.posTable[twt.RRT[j-3]], twt.posTable[twt.RRT[j-2]], twt.biasedCoefs[i])
      helperVec:setLerp(twt.dirTable[twt.RRT[j-1]], twt.dirTable[twt.RRT[j]], twt.biasedCoefs[i]) -- LERP corner direction
      helperVec:normalize()
      local rayLen = castRay(tmpVec, helperVec, min(twt.rayMins[i], rayDist))
      if twt.rayMins[i] > rayLen or rayLen == rayDist then
        twt.minRayCoefs[i] = twt.biasedCoefs[i]
        twt.rayMins[i] = rayLen
      else
        tmpVec:setLerp(twt.posTable[twt.RRT[j-3]], twt.posTable[twt.RRT[j-2]], twt.minRayCoefs[i])
        helperVec:setLerp(twt.dirTable[twt.RRT[j-1]], twt.dirTable[twt.RRT[j]], twt.minRayCoefs[i]) -- LERP corner direction
        helperVec:normalize()
        twt.rayMins[i] = castRay(tmpVec, helperVec, min(max(2 * twt.rayMins[i], 0.02), rayDist))
      end
      twt.blueNoiseRR = getBlueNoise1d(twt.blueNoiseRR)
      twt.blueNoiseCoefs[i] = getBlueNoise1d(twt.blueNoiseCoefs[i])
      local criticality = 2 * twt.rayMins[i] / (twt.rayMins[i] + rayDist) + 0.25
      twt.biasedCoefs[i] = biasGainFun(twt.blueNoiseCoefs[i], twt.minRayCoefs[i], criticality)
    end
    local minRayDist = min(twt.rayMins[1], twt.rayMins[2], twt.rayMins[3], twt.rayMins[4], twt.rayMins[5], twt.rayMins[6], twt.rayMins[7], twt.rayMins[8])

    twt.sampleCounter = twt.sampleCounter + 1
    if twt.state == 0 then
      if twt.sampleCounter * dt > max(0.5, min(50 * dt, 2.5)) and ai.speed <= 0.5 then -- TODO: Optimize sample count condition
        twt.state = 1
      else
        local speed = max(0, ai.speed - 0.25)
        local throttle = max(0, -sign(speed * dirVel)) * 0.3
        local brake = max(0, sign(speed * dirVel)) * 0.3
        driveCar(0, throttle, brake, 0)
      end
    end

    if twt.state == 1 then  -- start driving
      if twt.targetSpeed < 0.66 or twt.minRay == "S" then -- TODO: Some branches may be consolidated
        if minRayDist == twt.rayMins[7] then
          twt.dirState[1] = 1
          twt.dirState[2] = sign2(dirTargetAxis)
          twt.minRay = "BL"
        elseif minRayDist == twt.rayMins[5] then
          twt.dirState[1] = 1
          twt.dirState[2] = sign2(dirTargetAxis)
          twt.minRay = "BR"
        elseif minRayDist == twt.rayMins[1] then
          twt.dirState[1] = -1
          twt.dirState[2] = -sign2(dirTargetAxis)
          twt.minRay = "FL"
          if twt.dirState[2] == 1 and twt.rayMins[8] < 0.4 and twt.targetSpeed < 0.6 then twt.dirState[2] = 0 end
        elseif minRayDist == twt.rayMins[3] then
          twt.dirState[1] = -1
          twt.dirState[2] = -sign2(dirTargetAxis)
          if twt.dirState[2] == -1 and twt.rayMins[4] < 0.4 and twt.targetSpeed < 0.6 then twt.dirState[2] = 0 end
          twt.minRay = "FR"
        elseif minRayDist == twt.rayMins[6] then
          twt.dirState[1] = 1
          twt.dirState[2] = sign2(dirTargetAxis)
          twt.minRay = "B"
        elseif minRayDist == min(twt.rayMins[4], twt.rayMins[8]) then
          local sideRuler = 0
          local minSide =  minRayDist == twt.rayMins[8] and "L" or "R"
          if minSide == "L" then
            sideRuler = ai.length * (1 - twt.minRayCoefs[8])
          else
            sideRuler = ai.length * twt.minRayCoefs[4]
          end
          twt.dirState[2] = 0
          if sideRuler < twt.rayMins[6] and dirTarget < 0 then --TODO : test this
            twt.dirState[1] = -1
          elseif (ai.length - sideRuler) < twt.rayMins[2] then
            twt.dirState[1] = 1
            if minSide == "L" then
              twt.dirState[2] = 1
            else
              twt.dirState[2] = -1
            end
          end
          twt.minRay = "S"
        else
          twt.dirState[1] = -1
          twt.dirState[2] = -sign2(dirTargetAxis)
          twt.minRay = "F"
        end
      end

      local threshold = min(ai.speed - 0.1, 0.66)
      local dirCoef, minDist = 1, nil --TODO: what is car is trapped/sandwiched?
      if twt.dirState[1] == -1 then -- reverse
        dirCoef = min(1.2 - dirTarget, 1) -- dirTarget -> targetSpeed modulation
        if twt.dirState[2] == -1 then -- steer left
          minDist = min(twt.rayMins[4], twt.rayMins[6], twt.rayMins[7])
        elseif twt.dirState[2] == 1 then -- steer right
          minDist = min(twt.rayMins[5], twt.rayMins[6], twt.rayMins[8])
        else -- no steering
          minDist = twt.rayMins[6]
          if twt.minRay ~= "S" then
            threshold = twt.rayMins[2] -- possibly max(threshold, twt.rayMins[2])
          end
        end
      else -- forward
        if twt.dirState[2] == -1 then
          minDist = min(twt.rayMins[1], twt.rayMins[2], twt.rayMins[8])
        elseif twt.dirState[2] == 1 then
          minDist = min(twt.rayMins[2], twt.rayMins[3], twt.rayMins[4])
        else
          minDist = twt.rayMins[2]
        end
      end

      local targetSpeed = sqrt(2 * g * min(aggression, ai.staticFrictionCoef) * max(0, minDist - threshold) * dirCoef)
      twt.targetSpeed = max(min(twt.speedSmoother:get(targetSpeed, dt), min(6, aggression * 6)), 0.3)
      local speedDif = twt.targetSpeed - twt.dirState[1] * sign2(dirVel) * ai.speed
      local steering = twt.steerSmoother:get(twt.dirState[2], dt)
      local pbrake = 0 -- * clamp(sign2(0.83 + ai.upVec:dot(gravityDir)), 0, 1) -- >= 10 deg
      local throttle, brake = 0, 0
      if twt.dirState[1] == -1 then
        throttle = clamp(-speedDif * 0.4, 0, 0.4)
        brake = clamp(speedDif * 0.2, 0, 1)
      elseif twt.dirState[1] == 1 then
        throttle = clamp(speedDif * 0.2, 0, 1)
        brake = clamp(-speedDif * 0.4, 0, 0.4)
      end
      driveCar(steering, throttle, brake, pbrake)
    end
  else
    twt.reset()

    local pbrake
    if ai.vel:dot(ai.dirVec) < 0 and ai.speed > 0.1 then
      -- TODO: handbrake when stoped or moving backward
      -- apply brake (in arcade mode throttle input when moving backwards activates the brakes) and or parkingbrake
      -- when vehicle is moving backwards but the target speed is effectively zero
      if ai.speed < 0.15 and targetSpeed <= 1e-5 then
        pbrake = 1
      else
        pbrake = 0
      end
      throttle = 0.5 * throttleCoef
      brake = 0
    else
      if (ai.speed > 4 and ai.speed < 30 and abs(dirAngle) > 0.97 and brake == 0) or (ai.speed < 0.15 and targetSpeed <= 1e-5) then
        -- The first condition was supposed to help the vehicles turn in tight corners by applying handbrake. This is very old logic. It might
        -- no longer be needed. Revise.
        -- The second condition is supposed to apply handbrake when the vehicle is at a stop but it looks to be unstable
        -- TODO: handbrake when turning
        pbrake = 1
      else
        pbrake = 0
      end
      throttle = throttle * throttleCoef
      brake = brake * brakeCoef
    end

    local aggSq = square(aggression + max(0, -(ai.dirVec:dot(gravityDir))))
    local rate = max(throttleSmoother[throttleSmoother:value() < throttle], 10 * aggSq * aggSq)
    throttle = throttleSmoother:getWithRateUncapped(throttle, dt, rate)

    driveCar(dirAngle, throttle, brake, pbrake)
  end
end

local function posOnPlan(pos, plan, dist)
  if not plan then return end
  dist = dist or 4
  dist = dist * dist
  local bestSeg, bestXnorm
  for i = 1, #plan-2 do
    local p0, p1 = plan[i].pos, plan[i+1].pos
    local xnorm1 = pos:xnormOnLine(p0, p1)
    if xnorm1 > 0 then
      local p2 = plan[i+2].pos
      local xnorm2 = pos:xnormOnLine(p1, p2)
      if xnorm1 < 1 then -- contained in segment i
        if xnorm2 > 0 then -- also partly contained in segment i+1
          local sqDistFromP1 = pos:squaredDistance(p1)
          if sqDistFromP1 <= dist then
            bestSeg = i
            bestXnorm = 1
            break -- break inside conditional
          end
        else
          local sqDistFromLine = pos:squaredDistance(p0 + (p1 - p0) * xnorm1)
          if sqDistFromLine <= dist then
            bestSeg = i
            bestXnorm = xnorm1
          end
          break -- break should be outside above conditional
        end
      elseif xnorm2 < 0 then
        local sqDistFromP1 = pos:squaredDistance(p1)
        if sqDistFromP1 <= dist then
          bestSeg = i
          bestXnorm = 1
        end
        break -- break outside conditional
      end
    else
      break
    end
  end

  return bestSeg, bestXnorm
end

local function aiPosOnPlan(plan)
  local planCount = plan.planCount
  local aiSeg = 1
  local aiXnormOnSeg = 0
  for i = 1, planCount-1 do
    local p0Pos, p1Pos = plan[i].pos, plan[i+1].pos
    local xnorm = ai.pos:xnormOnLine(p0Pos, p1Pos)
    if xnorm < 1 then
      if i < planCount - 2 then
        local nextXnorm = ai.pos:xnormOnLine(p1Pos, plan[i+2].pos)
        if nextXnorm >= 0 then
          local p1Radius = plan[i+1].radiusOrig
          if ai.pos:squaredDistance(linePointFromXnorm(p1Pos, plan[i+2].pos, nextXnorm)) <
              square(ai.width + lerp(p1Radius, plan[i+2].radiusOrig, min(1, nextXnorm))) then
            aiXnormOnSeg = nextXnorm
            aiSeg = i + 1
            break
          end
        end
      end
      aiXnormOnSeg = xnorm
      aiSeg = i
      break
    end
  end

  local disp = 0
  if aiSeg > 1 then
    local sumLen = 0
    disp = aiSeg - 1
    for i = 1, disp do
      sumLen = sumLen + plan[i].length
    end

    for i = 1, plan.planCount do
      plan[i] = plan[i+disp]
      if disp > 0 and i + disp > plan.planCount then
        velocities[i] = vec3(0,0,0)
      else
        velocities[i] = velocities[i+disp]
      end
    end

    plan.planCount = plan.planCount - disp
    plan.planLen = max(0, plan.planLen - sumLen)
    plan.stopSeg = max(1, plan.stopSeg - disp)
  end

  plan.aiXnormOnSeg = aiXnormOnSeg
  plan.aiSeg = aiSeg - disp
end

-- returns the node index
local function getLastNodeWithinDistance(plan, dist)
  dist = dist - plan[1].length * (1 - plan.aiXnormOnSeg)
  if dist < 0 then
    return 1
  end

  local planSeg = plan.planCount
  for i = 2, plan.planCount-1 do
    dist = dist - plan[i].length
    if dist < 0 then
      planSeg = i
      break
    end
  end

  return planSeg
end

local function calculateTarget(plan)
  aiPosOnPlan(plan)
  local targetLength = max(ai.speed * parameters.lookAheadKv, 4.5)

  if plan.planCount >= 3 then
    local xnorm = clamp(plan.aiXnormOnSeg, 0, 1)
    targetLength = max(targetLength, plan[1].length * (1 - xnorm), plan[2].length * xnorm)
  end

  local remainder = targetLength

  local targetPos = vec3(plan[plan.planCount].pos)
  local targetSeg = max(1, plan.planCount-1)
  local prevPos = linePointFromXnorm(plan[1].pos, plan[2].pos, plan.aiXnormOnSeg) -- ai.pos

  local segVec, segLen = vec3(), nil
  for i = 2, plan.planCount do
    local pos = plan[i].pos

    segVec:setSub2(pos, prevPos)
    segLen = segLen or segVec:length()

    if remainder <= segLen then
      targetSeg = i - 1
      targetPos:setScaled2(segVec, remainder / (segLen + 1e-30)); targetPos:setAdd(prevPos)

      -- smooth target
      local xnorm = clamp(targetPos:xnormOnLine(prevPos, pos), 0, 1)
      local lp_n1n2 = linePointFromXnorm(prevPos, pos, xnorm * 0.5 + 0.25)
      if xnorm <= 0.5 then
        if i >= 3 then
          targetPos = linePointFromXnorm(linePointFromXnorm(plan[i-2].pos, prevPos, xnorm * 0.5 + 0.75), lp_n1n2, xnorm + 0.5)
        end
      else
        if i <= plan.planCount - 2 then
          targetPos = linePointFromXnorm(lp_n1n2, linePointFromXnorm(pos, plan[i+1].pos, xnorm * 0.5 - 0.25), xnorm - 0.5)
        end
      end
      break
    end

    prevPos = pos
    remainder = remainder - segLen
    segLen = plan[i].length
  end

  plan.targetPos = targetPos
  plan.targetSeg = targetSeg
end

local function targetsCompatible(baseRoute, newRoute)
  local baseTvec = baseRoute.plan.targetPos - ai.pos
  local newTvec = newRoute.plan.targetPos - ai.pos
  if ai.speed < 2 then return true end
  if newTvec:dot(ai.dirVec) * baseTvec:dot(ai.dirVec) <= 0 then return false end
  local baseTargetRight = baseTvec:cross(ai.upVec); baseTargetRight:normalize()
  return abs(newTvec:normalized():dot(baseTargetRight)) * ai.speed < 2
end

local function getMinPlanLen(limLow, speed, accelg)
  -- given current speed, distance required to come to a stop if I can decelerate at 0.2g
  limLow = limLow or 150
  speed = speed or ai.speed
  accelg = max(0.2, accelg or 0.2)
  return min(550, max(limLow, 0.5 * speed * speed / (accelg * g)))
end

local function pickAiWp(wp1, wp2, dirVec)
  dirVec = dirVec or ai.dirVec
  local vec1 = mapData.positions[wp1] - ai.pos
  local vec2 = mapData.positions[wp2] - ai.pos
  local dot1 = vec1:dot(dirVec)
  local dot2 = vec2:dot(dirVec)
  if (dot1 * dot2) <= 0 then
    if dot1 < 0 then
      return wp2, wp1
    end
  else
    if vec2:squaredLength() < vec1:squaredLength() then
      return wp2, wp1
    end
  end
  return wp1, wp2
end

local function pathExtend(path, newPath)
  if newPath == nil then return end
  local pathCount = #path
  if path[pathCount] ~= newPath[1] then return end
  pathCount = pathCount - 1
  for i = 2, #newPath do
    path[pathCount+i] = newPath[i]
  end
end

-- http://cnx.org/contents/--TzKjCB@8/Projectile-motion-on-an-inclin
local function projectileSqSpeedToRangeRatio(pos1, pos2, pos3)
  local sinTheta = (pos2.z - pos1.z) / pos1:distance(pos2)
  local sinAlpha = (pos3.z - pos2.z) / pos2:distance(pos3)
  local cosAlphaSquared = max(1 - sinAlpha * sinAlpha, 0)
  local cosTheta = sqrt(max(1 - sinTheta * sinTheta, 0)) -- in the interval theta = {-pi/2, pi/2} cosTheta is always positive
  return 0.5 * g * cosAlphaSquared / max(cosTheta * (sinTheta*sqrt(cosAlphaSquared) - cosTheta*sinAlpha), 0)
end

local function getPathLen(path, startIdx, stopIdx)
  if not path then return end
  startIdx = startIdx or 1
  stopIdx = stopIdx or #path
  local positions = mapData.positions
  local pathLen = 0
  for i = startIdx+1, stopIdx do
    pathLen = pathLen + positions[path[i-1]]:distance(positions[path[i]])
  end

  return pathLen
end

local function getPathBBox(path, startIdx, stopIdx)
  if not path then return end
  startIdx = startIdx or 1
  stopIdx = stopIdx or #path

  local positions = mapData.positions
  local p = positions[path[startIdx]]
  local v = positions[path[stopIdx]] + p; v:setScaled(0.5)
  local r = getPathLen(path, startIdx, stopIdx) * 0.5

  return {v.x - r, v.y - r, v.x + r, v.y + r}, v, r
end

local function waypointInPath(path, waypoint, startIdx, stopIdx)
  if not path or not waypoint then return end
  startIdx = startIdx or 1
  stopIdx = stopIdx or #path
  for i = startIdx, stopIdx do
    if path[i] == waypoint then
      return i
    end
  end
end

local function getPlanLen(plan, from, to)
  from = max(1, from or 1)
  to = min(plan.planCount-1, to or math.huge)
  local planLen = 0
  for i = from, to do
    planLen = planLen + plan[i].length
  end

  return planLen
end

local function abortUpcommingLaneChange()
  if not currentRoute then return end
  if currentRoute.laneChanges[1] then
    currentRoute.laneChanges[1].side = 0
  end
  local lastPlanPidx = currentRoute.plan[currentRoute.plan.planCount].pathidx
  for _, lc in ipairs(currentRoute.laneChanges) do
    if lc.pathIdx <= lastPlanPidx then
      lc.side = 0
    end
  end
end

local function updatePlanLen(plan, j, k)
  --profilerPushEvent("ai_update_planLen")
  -- bulk recalculation of plan edge lengths and length of entire plan
  -- j: index of earliest node position that has changed
  -- k: index of latest node position that has changed
  j = max((j or 1) - 1, 1)
  k = min(k or plan.planCount, plan.planCount-1)

  local planLen = plan.planLen
  for i = j, k do
    local edgeLen = plan[i+1].pos:distance(plan[i].pos)
    planLen = planLen - plan[i].length + edgeLen
    plan[i].length = edgeLen
  end
  plan.planLen = planLen
  --profilerPopEvent("ai_update_planLen")
end

-- expand lane lateral limits of this plan node to the lane range limits
local function openLaneToLaneRange(planNode)
  local roadHalfWidth = planNode.halfWidth
  planNode.laneLimLeft = linearScale(planNode.rangeLeft, 0, 1, -roadHalfWidth, roadHalfWidth)
  planNode.laneLimRight = linearScale(planNode.rangeRight, 0, 1, -roadHalfWidth, roadHalfWidth)
  planNode.lanesOpen = true
end

-- expand lane lateral limits to the lane range for all nodes up to and including idx
local function openPlanLanesToLaneRange(plan, idx)
  plan = plan or (currentRoute and currentRoute.plan)
  if not plan then return end
  for i = 1, min(plan.planCount, idx) do
    openLaneToLaneRange(plan[i])
  end
end

local function laneChange(plan, dist, signedDisp)
  if not plan and currentRoute then plan = currentRoute.plan end
  if not plan then return end

  -- Apply node displacement
  local invDist = 1 / (dist + 1e-30)
  local curDist, normalDispVec = 0, vec3()
  for i = 2, plan.planCount do
    openLaneToLaneRange(plan[i])
    curDist = curDist + plan[i-1].length
    plan[i].lateralXnorm = clamp(plan[i].lateralXnorm + signedDisp * min(curDist * invDist, 1), plan[i].laneLimLeft, plan[i].laneLimRight)
    normalDispVec:setScaled2(plan[i].normal, plan[i].lateralXnorm)
    plan[i].pos:setAdd2(plan[i].posOrig, normalDispVec)

    -- Recalculate vec and dirVec
    plan[i].vec:setSub2(plan[i-1].pos, plan[i].pos); plan[i].vec.z = 0
    plan[i].dirVec:set(plan[i].vec)
    plan[i].dirVec:normalize()
  end

  updatePlanLen(plan)

  --[[ For debugging
  table.clear(newPositionsDebug)
  for i = 1, #newPositions do
    newPositionsDebug[i] = vec3(newPositions[i])
  end
  --]]
end

local function setStopPoint(plan, dist, args)
  if not plan and currentRoute then
    plan = currentRoute.plan
  end
  if not plan then return end

  if not dist then -- reset stop segment
    plan.stopSeg = math.huge
    return
  end

  if (args or E).avoidJunction and currentRoute.path then -- prevents stopping directly in junctions
    -- this code is temporary, and inefficient...
    local seg
    while true do
      seg = getLastNodeWithinDistance(plan, dist)
      local nid = currentRoute.path[plan[seg].pathidx]
      if seg < plan.planCount - 1 and tableSize(mapData.graph[nid]) > 2 and plan[seg].pos:squaredDistance(mapData.positions[nid]) <= square(mapData.radius[nid]) then
        dist = dist + 20
      else
        break
      end
    end
    plan.stopSeg = seg
  else
    plan.stopSeg = getLastNodeWithinDistance(plan, dist)
  end
end

local function numOfLanesFromRadius(rad1, rad2)
  return max(1, math.floor(min(rad1, rad2 or math.huge) * 2 / 3.61 + 0.5)) -- math.floor(min(rad1, rad2) / 2.7) + 1
end

local laneStringBuffer = buffer.new()
local function flipLanes(lanes)
  -- ex. '--+++' becomes '---++'
  for i = #lanes, 1, -1 do
    laneStringBuffer:put(lanes:byte(i) == 43 and '-' or lanes:byte(i) == 45 and '+' or '0')
  end
  return laneStringBuffer:get()
end

-- returns the number of lanes in a given direction
local function numOfLanesInDirection(lanes, dir)
  -- lanes: a lane string
  -- dir: '+' or '-'
  dir = dir == '+' and 43 or dir == '-' and 45
  local lanesN = 0
  for i = 1, #lanes, 1 do
    if lanes:byte(i) == dir then
      lanesN = lanesN + 1
    end
  end
  return lanesN
end

-- Returns the lane configuration of an edge as traversed in the fromNode -> toNode direction
-- if an edge does not have lane data they are deduced from the node radii
local function getEdgeLaneConfig(fromNode, toNode)
  local lanes
  local edge = mapData.graph[fromNode][toNode]
  if edge.lanes then
    lanes = edge.lanes
  else -- make up some lane data in case they don't exist
    if edge.oneWay then
      local numOfLanes = numOfLanesFromRadius(mapData.radius[fromNode], mapData.radius[toNode])
      lanes = string.rep("+", numOfLanes)
    else
      local numOfLanes = max(1, math.floor(numOfLanesFromRadius(mapData.radius[fromNode], mapData.radius[toNode]) * 0.5))
      if mapmgr.rules.rightHandDrive then
        lanes = string.rep("+", numOfLanes)..string.rep("-", numOfLanes)
      else
        lanes = string.rep("-", numOfLanes)..string.rep("+", numOfLanes)
      end
    end
  end

  return edge.inNode == fromNode and lanes or flipLanes(lanes) -- flip lanes string based on inNode data
end

-- Calculate the edge incident on wp2 which is most similar to the edge wp1->wp2
local function roadNaturalContinuation(wp1, wp2)
  local inLaneConfig = getEdgeLaneConfig(wp1, wp2)
  local inRadiuswp2, inRadiuswp1 = mapData:getEdgeRadii(wp2, wp1)
  local inEdgeDir = vec3(); inEdgeDir:setSub2(mapData:getEdgePositions(wp2, wp1)); inEdgeDir:normalize()
  local laneFlow = mapData.graph[wp1][wp2].drivability * 4 * min(inRadiuswp2, inRadiuswp1) / #inLaneConfig
  local inLaneCount = numOfLanesInDirection(inLaneConfig, '+')
  local inFwdFlow = inLaneCount * laneFlow
  local inLaneCountOpposite = (#inLaneConfig - inLaneCount)
  local inBackFlow = inLaneCountOpposite * laneFlow
  local outEdgeDir, maxOutflow, minNode = vec3(), 0, nil
  for k, v in pairs(mapData.graph[wp2]) do
    if k ~= wp1 then
      local outLaneConfig = getEdgeLaneConfig(wp2, k)
      local numOfOutLanes = numOfLanesInDirection(outLaneConfig, '+')
      outEdgeDir:setSub2(mapData:getEdgePositions(k, wp2)); outEdgeDir:normalize()
      local dirCoef = 0.5 * max(0, 1 + outEdgeDir:dot(inEdgeDir))
      local outLaneCountOpposite = (#outLaneConfig - numOfOutLanes)
      local outRadiuswp2, outRadiusk = mapData:getEdgeRadii(wp2, k)
      if numOfOutLanes == inLaneCount and  outLaneCountOpposite == inLaneCountOpposite then
        laneFlow = mapData.graph[wp2][k].drivability * 4 * 0.5 * (inRadiuswp2 + outRadiuswp2) / #outLaneConfig
      else
        laneFlow = mapData.graph[wp2][k].drivability * 4 * min(outRadiuswp2, outRadiusk)/ #outLaneConfig
      end
      local outFwdFlow = min(inFwdFlow, numOfOutLanes * laneFlow)
      local outBackFlow = min(inBackFlow, outLaneCountOpposite * laneFlow)
      local outflow = outFwdFlow * (1 + outBackFlow) * dirCoef

      if outflow > maxOutflow then
        maxOutflow = outflow
        minNode = k
      end
    end
  end

  return minNode
end


-- returns the lane indices of the left most and right most lanes in the direction of travel
local function laneRangeIdx(laneConfig)
  local numOfLanes = #laneConfig
  local leftIdx, rightIdx = 1, numOfLanes
  for i = 1, numOfLanes do
    if laneConfig:byte(i) == 43 then -- "+"
      leftIdx = i
      break
    end
  end

  for i = numOfLanes, 1, -1 do
    if laneConfig:byte(i) == 43 then -- "+"
      rightIdx = i
      break
    end
  end

  return leftIdx, rightIdx, numOfLanes
end

-- returns the lane lateral xnorm limits (boundaries in [0, 1] range 0 being the left boundary)
-- of the left most and right most lanes in the direction of travel and the number of lanes in that range.
-- This range might include lanes in the opposite direction if they are interleaved with lanes in the direction of travel
-- ex. '--++-++' the left most lane is lane 3, the right most lane is lane 7. The range is from lane 3 to lane 7 inclusive.
local function laneRange(laneConfig)
  local leftLim, rightLim, numOfLanes = laneRangeIdx(laneConfig)
  return (leftLim - 1) / numOfLanes, rightLim / numOfLanes, rightLim - leftLim + 1
end

-- Splits the lane string into three parts 1:leftIdx-1, leftIdx:rightIdx, rightIdx+1:numOfLanes and returns the three strings
-- leftIdx is the indice of the left most lane in the direction of travel
-- rightIdx is the indice of the right most lane in the direction of travel
-- therefore leftIdx:rightIdx is the lane string from the left most to the right most lane in the direction of travel
local function splitLaneRange(laneConfig)
  local leftIdx, rightIdx, numOfLanes = laneRangeIdx(laneConfig)
  --leftIdx = leftIdx
  --rightIdx = rightIdx

  return laneConfig:sub(1, leftIdx-1), laneConfig:sub(leftIdx, rightIdx), laneConfig:sub(rightIdx+1, numOfLanes)
end

-- Lateral xnorm limits ([0, 1]) of the left most and right most lanes from "lane" in the direction of "lane"
local function getLaneRangeFromLane(laneConfig, lane)
  -- laneConfig: a string representing lane configuration ex. "-a-a+a+a"
  -- lane: the lane number (1 to n) counting from left to right in the direction of travel
  local numOfLanes = #laneConfig
  local leftIdx, rightIdx = lane, lane
  -- search left
  for i = lane-1, 1, -1 do
    if laneConfig:byte(i) == 43 then -- "+"
      leftIdx = i
    else
      break
    end
  end

  -- search right
  for i = lane+1, numOfLanes do
    if laneConfig:byte(i) == 43 then -- "+"
      rightIdx = i
    else
      break
    end
  end

  return (leftIdx-1) / numOfLanes, rightIdx / numOfLanes, leftIdx, rightIdx
end

-- Calculates the composite lane configuration coming into newNode
-- and adjusted lateral position, lane limits and lane range of the last plan node.
local function processNodeIncommingLanes(newNode, planNode)
  local leftRange, centerRange, rightRange = splitLaneRange(newNode.inEdgeLanes)
  local latXnorm = planNode.lateralXnorm
  local laneLimLeft = planNode.laneLimLeft
  local laneLimRight = planNode.laneLimRight
  local halfWidth = planNode.halfWidth
  local numOfOutLanes = numOfLanesInDirection(newNode.outEdgeLanes, "+")
  local numOfInLanes = numOfLanesInDirection(newNode.inEdgeLanes, "+")
  local defaultLaneWidth = min(2 * halfWidth / (#newNode.inEdgeLanes), 3.45)
  local inEdgeDrivabilityInv = 1 / ((newNode.inEdgedrivability or 1) + 1e-30)
  if not planNode.rangeLeft then planNode.rangeLeft, planNode.rangeRight = laneRange(newNode.inEdgeLanes) end
  local rangeLeft = linearScale(planNode.rangeLeft or 0, 0, 1, -halfWidth, halfWidth)
  local rangeRight = linearScale(planNode.rangeRight or 1, 0, 1, -halfWidth, halfWidth)

  for nodeId, edgeData in pairs(mapData.graph[newNode.name]) do
    if nodeId ~= newNode.nextNodeInPath and nodeId ~= newNode.prevNodeInPath then -- and not mapmgr.signalsData.nodes[newNode.name]
      local lanes = getEdgeLaneConfig(nodeId, newNode.name)
      local thisEdgeInLanes = numOfLanesInDirection(lanes, '+')
      if thisEdgeInLanes > 0 then -- TODO: Should also possibly include traffic light data
        local nodePos = mapData.positions[nodeId]
        local dirRatio = max(0, (mapData.positions[newNode.nextNodeInPath or newNode.name] - newNode.posOrig):normalized():dot((newNode.posOrig - nodePos):normalized()))
        local drivabilityRatio = min(1, edgeData.drivability * inEdgeDrivabilityInv)
        thisEdgeInLanes = math.floor(thisEdgeInLanes * dirRatio * drivabilityRatio + 0.5)

        if thisEdgeInLanes > 0 then
          if newNode.inEdgeNormal:dot(nodePos) < newNode.inEdgeNormal:dot(newNode.posOrig) then -- coming into newNode from the left
            numOfInLanes = numOfInLanes + thisEdgeInLanes
            centerRange = string.rep("+", thisEdgeInLanes)..centerRange
            local radius = thisEdgeInLanes * defaultLaneWidth * 0.5
            latXnorm = latXnorm + radius
            laneLimLeft = laneLimLeft + radius
            laneLimRight = laneLimRight + radius
            halfWidth = halfWidth + radius
            rangeLeft = rangeLeft - radius
            rangeRight = rangeRight + radius -- TODO: is this correct?
          elseif numOfInLanes < numOfOutLanes then
            local capInLanes = min(numOfInLanes + thisEdgeInLanes, numOfOutLanes)
            thisEdgeInLanes = capInLanes - numOfInLanes
            numOfInLanes = capInLanes
            local radius = thisEdgeInLanes * defaultLaneWidth * 0.5
            centerRange = centerRange..string.rep("+", thisEdgeInLanes)
            latXnorm = latXnorm - radius
            laneLimLeft = laneLimLeft - radius
            laneLimRight = laneLimRight - radius
            halfWidth = halfWidth + radius
            rangeLeft = rangeLeft - radius
            rangeRight = rangeRight + radius
          end
        end
      end
    end
  end

  return leftRange..centerRange..rightRange, latXnorm, laneLimLeft, laneLimRight, rangeLeft, rangeRight, halfWidth
end

-- Calculate the most appropriate lane of laneConfig
local function getBestLane(laneConfig, nodeLatPos, laneLeftLimLatPos, laneRightLimLatPos, plan, newNode)
  -- nodeLatPos, laneLeftLimLatPos, laneRightLimLatPos are in the [0, 1] interval
  local laneWidth = laneRightLimLatPos - laneLeftLimLatPos
  local numOfLanes = max(1, #laneConfig)
  local bestError = math.huge
  local bestLane, newLaneLimLeft, newLaneLimRight
  local planPos, dirVec
  if plan then
    planPos = plan[plan.planCount].pos
    dirVec = plan[plan.planCount].pos - plan[max(1, plan.planCount-1)].pos; dirVec:normalize()
  else
    planPos = vec3()
    dirVec = planPos
    newNode = {}
    newNode.posOrig = planPos
    newNode.radiusOrig = 0
    newNode.halfWidth = 0
    newNode.normal = planPos
    newNode.outEdgeLanes = laneConfig
  end
  if #newNode.outEdgeLanes == #laneConfig then -- TODO: this might not be correct
    dirVec:set(0, 0, 0)
  end
  local newNodeWidthVec = newNode.halfWidth * newNode.normal
  for i = 1, numOfLanes do -- traverse lanes in laneConfig
    local thisLaneLimLeft, thisLaneLimRight = (i - 1) / numOfLanes, i / numOfLanes
    local thisLaneLatPos = (thisLaneLimRight + thisLaneLimLeft) * 0.5
    local laneDir = (newNode.posOrig + (thisLaneLatPos * 2 - 1) * newNodeWidthVec) - planPos; laneDir:normalize()

    local colinearityError = 1 - max(0, dirVec:dot(laneDir))
    local distError = abs(thisLaneLatPos - nodeLatPos)
    local overlapError = laneWidth - max(0, min(thisLaneLimRight, laneRightLimLatPos) - max(thisLaneLimLeft, laneLeftLimLatPos))
    local directionError = laneConfig:byte(i) == 43 and 0 or 1
    local totalError = distError + overlapError * 10 + directionError * 100 + (numOfLanes - i) * 0.1 + colinearityError * 3

    if totalError < bestError then
      bestError = totalError
      bestLane = i
      newLaneLimLeft = thisLaneLimLeft
      newLaneLimRight = thisLaneLimRight
    end
  end

  return bestLane, newLaneLimLeft, newLaneLimRight -- lateral positions are in the [0, 1] interval
end

local function getPathNodePosition(route, i)
  local path = route.path
  local wp1 = path[i-1] or route.plan[1].wp
  local wp2 = path[i]
  local wp3 = path[i+1]
  --dump('---- > in', i, path[i])
  if not wp1 and not wp3 then
    --dump('!!!!!!!!!!!!!!', path, objectId)
    return mapData.positions[wp2]:copy()
  elseif not wp1 then
    local wp2Pos = mapData:getEdgePositions(wp2, wp3)
    return wp2Pos:copy()
  elseif not wp3 then
    local _, wp2Pos = mapData:getEdgePositions(wp1, wp2)
    return wp2Pos:copy()
  else
    local e1P1, e1P2 = mapData:getEdgePositions(wp1, wp2)
    local e2P1, e2P2 = mapData:getEdgePositions(wp2, wp3)
    --dump(wp1, wp2, wp3, e1P2:squaredDistance(e2P1))
    if e1P2:squaredDistance(e2P1) < 0.005 then
      --dump('b0')
      return (e1P2 + e2P1) * 0.5
    else
      local e1Xnorm, e2Xnorm = closestLinePoints(e1P1, e1P2, e2P1, e2P2)
      local e2Xnorm2 = closestLinePoints(e2P1, e2P2, e1P1, e1P2)
      local _, e1R2 = mapData:getEdgeRadii(wp1, wp2)
      local e2R1 = mapData:getEdgeRadii(wp2, wp3)

      if e1Xnorm == 0 and e2Xnorm2 == 0 then
        -- segments are parallel
        --dump('b1')
        return (e1P2 + e2P1) * 0.5

      elseif e1Xnorm >= 0 and (e1Xnorm - 1) * e1P2:distance(e1P1) <= e1R2 and e2Xnorm * e2P1:distance(e2P2) >= -e2R1 and e2Xnorm <= 1 then
        -- intersection is within the (radius augmented at P2) e1 and e2 segments
        --dump('b2', 'e1Xnorm = ', e1Xnorm, 'e2Xnorm = ', e2Xnorm)
        local p1 = linePointFromXnorm(e1P1, e1P2, e1Xnorm)
        local p2 = linePointFromXnorm(e2P1, e2P2, e2Xnorm)
        p1:setAdd(p2); p1:setScaled(0.5)
        return p1

      elseif e2Xnorm < 1 and e1Xnorm >= 0 and (e1Xnorm - 1) * e1P2:distance(e1P1) <= e1R2 then
        -- intersection is within (radius augmented at P2) e1 segment and not furnter than the end of e2 (enures that it is not over segment 2 end, if it is too short)
        --dump('b3', 'e1Xnorm = ', e1Xnorm, 'e2Xnorm = ', e2Xnorm)
        local segLen = e1P2:distance(e1P1)
        return linePointFromXnorm(e1P1, e1P2, max(e1Xnorm, 1 - e1R2/segLen))

      elseif e1Xnorm > 0 and e2Xnorm * e2P1:distance(e2P2) >= -e2R1 and e2Xnorm <= 1 then
        -- intersection is within (radius augmented at P2) e2 segment and infront of e1P1
        --dump('b4', 'e1Xnorm = ', e1Xnorm, 'e2Xnorm = ', e2Xnorm)
        local segLen = e2P1:distance(e2P2)
        return linePointFromXnorm(e2P1, e2P2, min(e2Xnorm, e2R1/segLen))

      elseif e2Xnorm >= 1 or e1Xnorm < 0 then
        -- intersection is over segment 2 end or before segment 1 start (particular case)
        --dump('b5')
        return (e1P2 + e2P1) * 0.5

      else
        -- intersection is between segments 1 and 2 but outside of radii extensions
        --dump('b6')
        local p1 = linePointFromXnorm(e1P1, e1P2, e1Xnorm)
        local p2 = linePointFromXnorm(e2P1, e2P2, e2Xnorm)
        p1:setAdd(p2); p1:setScaled(0.5)
        local avgPoint = (e1P2 + e2P1) * 0.5
        local avgPointToP1Line = p1 - avgPoint
        return avgPoint + max(0, min(1, (e1R2 + e2R1) * 0.5 / avgPointToP1Line:length())) * avgPointToP1Line
      end
    end
  end
end

local function getPathNodeRadius(path, i)
  if not path[i-1] and not path[i+1] then
    return mapData.radius[path[i]]
  elseif not path[i-1] then
    local wp1Rad = mapData:getEdgeRadii(path[i], path[i+1])
    return wp1Rad
  elseif not path[i+1] then
    local _, wp2Rad = mapData:getEdgeRadii(path[i-1], path[i])
    return wp2Rad
  else
    local wp1Pos, wp2Pos = mapData:getEdgePositions(path[i-1], path[i])
    local wp3Pos, wp4Pos = mapData:getEdgePositions(path[i], path[i+1])
    local e1Xnorm, e2Xnorm = closestLineSegmentPoints(wp1Pos, wp2Pos, wp3Pos, wp4Pos)
    local wp1Rad, wp2Rad = mapData:getEdgeRadii(path[i-1], path[i])
    local wp3Rad, wp4Rad = mapData:getEdgeRadii(path[i], path[i+1])
    local r1 = wp1Rad + (wp2Rad - wp1Rad) * e1Xnorm
    local r2 = wp3Rad + (wp4Rad - wp3Rad) * e2Xnorm
    return (r1 + r2) * 0.5
  end
end

local function buildNextRoute(route)
  local plan, path = route.plan, route.path
  local planCount = plan.planCount
  local nextPathIdx = (plan[planCount].pathidx or 0) + 1 -- if the first plan node is the ai.pos it does not have a pathidx value yet

  if loopPath == true and noOfLaps and noOfLaps > 1 and not path[nextPathIdx] then -- in case the path loops
    local loopPathId
    local pathCount = #path
    local lastWayPoint = path[pathCount]
    for i = 1, pathCount do
      if lastWayPoint == path[i] then
        loopPathId = i
        break
      end
    end
    nextPathIdx = 1 + loopPathId -- nextPathIdx % #path
    noOfLaps = noOfLaps - 1
  end

  local newNodeName = path[nextPathIdx]
  if not newNodeName then return end
  local graph = mapData.graph
  if not graph[newNodeName] then return end

  -- gather information about new node
  local tmpPos = getPathNodePosition(route, nextPathIdx)
  local newNode = {
    name = newNodeName,
    posOrig = tmpPos,
    pos = tmpPos:copy(),
    radiusOrig = getPathNodeRadius(path, nextPathIdx),
    biNormal = -mapmgr.surfaceNormalBelow(mapData.positions[newNodeName], mapData.radius[newNodeName] * 0.5),
    prevNodeInPath = path[nextPathIdx-1],
    inEdgeDrivability = nil,
    inEdgeLanes = nil, -- lanes going into the node along the path
    inEdgeSpeedLimit = nil,
    nextNodeInPath = path[nextPathIdx+1],
    outEdgeLanes = nil, -- lanes coming out of the node along the path
    outEdgeSpeedLimit = nil,
  }

  if newNode.prevNodeInPath then
    newNode.prevNodePos = mapData.positions[newNode.prevNodeInPath]
    local link = graph[newNode.prevNodeInPath][newNode.name]
    if link then
      newNode.inEdgeLanes = getEdgeLaneConfig(newNode.prevNodeInPath, newNode.name)
      newNode.inEdgeSpeedLimit = link.speedLimit
      newNode.inEdgeDrivability = link.drivability
    end
  else -- if previous plan node is the ai.pos then
    newNode.prevNodePos = vec3(plan[1].posOrig)
    if planCount == 1 and plan[1].wp then -- check whether information is available
      --newNode.inEdgeLanes = plan[1].lanes -- TODO: use plan[1].wp to get lane configuration instead of saving the lane configuration in plan[1].lanes?
      newNode.prevNodeInPath = plan[1].wp
      newNode.inEdgeLanes = getEdgeLaneConfig(newNode.prevNodeInPath, newNode.name)
      newNode.inEdgeDrivability = graph[newNode.prevNodeInPath][newNode.name].drivability
    end
  end

  -- if there is no nextNodeInPath can we deduce it by elimination?
  -- we need to see if there is a unique node towards which we can lawfully drive
  if not newNode.nextNodeInPath then
    local nextPosibleNode = nil
    for k, v in pairs(graph[newNode.name]) do
      if k ~= newNode.prevNodeInPath then
        if numOfLanesInDirection(getEdgeLaneConfig(newNode.name, k), '+') > 0 then
          if nextPosibleNode then
            nextPosibleNode = nil
            break
          else
            nextPosibleNode = k
          end
        end
      end
    end
    newNode.nextNodeInPath = nextPosibleNode
  end

  if newNode.nextNodeInPath then
    local link = graph[newNode.name][newNode.nextNodeInPath]
    if link then
      newNode.outEdgeLanes = getEdgeLaneConfig(newNode.name, newNode.nextNodeInPath)
      newNode.outEdgeSpeedLimit = link.speedLimit
    end
  else
    if M.mode ~= 'traffic' then
      newNode.outEdgeLanes = newNode.inEdgeLanes
      newNode.outEdgeSpeedLimit = newNode.inEdgeSpeedLimit
    else
      return
    end
  end

  if newNode.outEdgeLanes and not newNode.inEdgeLanes then
    newNode.inEdgeLanes = newNode.outEdgeLanes
  end

  -- Adjust last plan node normal given information about node to be inserted:
  -- The normal of the node that is currently the last in the plan may need to be updated
  -- either because the path has been extended (where previously it was the last node in the path)
  -- or because the path has changed from this node forwards
  if planCount > 1 then
    if plan[planCount].wayPointAhead ~= path[nextPathIdx] then
      local norm1 = plan[planCount].biNormal:cross(plan[planCount].posOrig - plan[planCount-1].posOrig); norm1:normalize()
      local norm2 = plan[planCount].biNormal:cross(newNode.posOrig - plan[planCount].posOrig); norm2:normalize()
      plan[planCount].normal:setAdd2(norm1, norm2)
      local tmp = plan[planCount].normal:length()
      plan[planCount].normal:setScaled(1 / (tmp + 1e-30))
      local chordLength = min(2 / tmp, (1 - norm1:dot(norm2) * 0.5) * tmp) -- 2 / tmp == cos(x/2) : x is angle between norm1, norm2
      plan[planCount].halfWidth = plan[planCount].radiusOrig * chordLength
    end
  else
    plan[planCount].normal:setSub2(newNode.posOrig, plan[planCount].posOrig)
    plan[planCount].normal:setCross(plan[planCount].biNormal, plan[planCount].normal)
    plan[planCount].normal:normalize()
  end

  -- Calculate normal of node to be inserted into the plan
  -- This normal is calculated from the normals of the two path edges incident on it
  newNode.inEdgeNormal = vec3()
  if newNode.prevNodeInPath then -- TODO: why not check for newNode.prevNodePos?
    local wp1Pos, wp2Pos = mapData:getEdgePositions(newNode.prevNodeInPath, newNode.name)
    newNode.inEdgeNormal:setSub2(wp2Pos, wp1Pos)
    newNode.inEdgeNormal:setCross(newNode.biNormal, newNode.inEdgeNormal)
    newNode.inEdgeNormal:normalize()
  end

  newNode.outEdgeNormal = vec3()
  if newNode.nextNodeInPath then
    local wp1Pos, wp2Pos = mapData:getEdgePositions(newNode.name, newNode.nextNodeInPath)
    newNode.outEdgeNormal:setSub2(wp2Pos, wp1Pos)
    newNode.outEdgeNormal:setCross(newNode.biNormal, newNode.outEdgeNormal)
    newNode.outEdgeNormal:normalize()
  end

  newNode.normal = newNode.inEdgeNormal + newNode.outEdgeNormal
  local tmp = newNode.normal:length()
  newNode.normal:setScaled(1 / (tmp + 1e-30))
  newNode.chordLength = min(2 / tmp, (1 - newNode.inEdgeNormal:dot(newNode.outEdgeNormal) * 0.5) * tmp) -- new node road width multiplier
  newNode.halfWidth = newNode.radiusOrig * newNode.chordLength

  local newNodeLaneLimLeft = 0
  local newNodeLaneLimRight = 1
  local newNodeRangeLeft = 0
  local newNodeRangeRight = 1
  local newNodeRangeLaneCount = 1
  local rangeBestLane = 0
  local bestLane
  local newNodeLaneConfig
  local newNodeRangeLeftIdx -- index of left most lane in range
  local newNodeRangeRightIdx -- index of right most lane in range

  if opt.driveInLaneFlag and newNode.inEdgeLanes then
    -- Consider lanes comming into newNode, scale/translate planNode lateral position and lane limits and add them to the in lane configuration as appropriate
    local inLaneConfig, planNodeLatPos, planNodelaneLimLeft, planNodelaneLimRight, planNodeRangeLeft, planNodeRangeRight, planNodeHalfWidth = processNodeIncommingLanes(newNode, plan[planCount]) -- lateral coordinates in [-r, r]

    -- Calculate lateral xnorm ranges of lanes in the direction of travel (in [0, 1])
    local outRangeLeft, outRangeRight, outRangeLaneCount = laneRange(newNode.outEdgeLanes)
    local inRangeLeft, inRangeRight, inRangeLaneCount = laneRange(inLaneConfig)

    -- Decide on the lane configuration of newNode: --> Retain the narrowest range
    local newNodeLaneConfigOrig
    if (inRangeRight - inRangeLeft) * outRangeLaneCount < (outRangeRight - outRangeLeft) * inRangeLaneCount then
      newNodeLaneConfig, newNodeRangeLeft, newNodeRangeRight, newNodeRangeLaneCount = inLaneConfig, inRangeLeft, inRangeRight, inRangeLaneCount
      newNodeLaneConfigOrig = newNode.inEdgeLanes
    else
      newNodeLaneConfig, newNodeRangeLeft, newNodeRangeRight, newNodeRangeLaneCount = newNode.outEdgeLanes, outRangeLeft, outRangeRight, outRangeLaneCount
      newNodeLaneConfigOrig = newNode.outEdgeLanes
    end

    local planNodeLatPosNrmd = linearScale(planNodeLatPos, planNodeRangeLeft, planNodeRangeRight, newNodeRangeLeft, newNodeRangeRight) -- TODO: lateralXnorm might be outside [inRangeLeft, inRangeRight]
    local planNodeLaneLimLeftNrmd = linearScale(planNodelaneLimLeft, planNodeRangeLeft, planNodeRangeRight, newNodeRangeLeft, newNodeRangeRight)
    local planNodeLaneLimRightNrmd = linearScale(planNodelaneLimRight, planNodeRangeLeft, planNodeRangeRight, newNodeRangeLeft, newNodeRangeRight)
    -- Calculate the most appropriate lane out of newNodeLaneConfig. This will be where to position the new node lateraly along the normal of newNode.
    bestLane, newNodeLaneLimLeft, newNodeLaneLimRight = getBestLane(newNodeLaneConfig, planNodeLatPosNrmd, planNodeLaneLimLeftNrmd, planNodeLaneLimRightNrmd, plan, newNode) -- lateral coordinates in [0, 1]

    -- Calculate the lane range (i.e. lateral limits of left most and right most lanes traveling in the same direction as bestLane, starting from bestLane)
    local rangeLeft, rangeRight = newNodeRangeLeft, newNodeRangeRight
    newNodeRangeLeft, newNodeRangeRight, newNodeRangeLeftIdx, newNodeRangeRightIdx = getLaneRangeFromLane(newNodeLaneConfig, bestLane) -- lateral coordinates in [0, 1]

    local rangeLeftOrig, rangeRightOrig = laneRange(newNodeLaneConfigOrig) -- Will this work when the lane config is not monotonic?
    newNodeRangeLeft = linearScale(newNodeRangeLeft, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    newNodeRangeRight = linearScale(newNodeRangeRight, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    --newNodeLaneLimLeft = linearScale(newNodeRangeLeft + (bestLane - newNodeRangeLeftIdx) * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth)
    --newNodeLaneLimRight = linearScale(newNodeRangeLeft + (bestLane - newNodeRangeLeftIdx) + 1) * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth)
    newNodeLaneLimLeft = linearScale(newNodeLaneLimLeft, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
    newNodeLaneLimRight = linearScale(newNodeLaneLimRight, rangeLeft, rangeRight, rangeLeftOrig, rangeRightOrig)
  end

  newNode.pos:setAdd(((newNodeLaneLimLeft + newNodeLaneLimRight) - 1) * newNode.halfWidth * newNode.normal)

  newNode.inEdgeNormal:setSub2(newNode.pos, plan[planCount].pos)
  newNode.inEdgeNormal:setCross(newNode.biNormal, newNode.inEdgeNormal)
  newNode.inEdgeNormal:normalize()
  newNode.normal = newNode.inEdgeNormal + newNode.outEdgeNormal

  local tmp = newNode.normal:length()
  newNode.normal:setScaled(1 / (tmp + 1e-30))
  newNode.chordLength = min(2 / tmp, (1 - newNode.inEdgeNormal:dot(newNode.outEdgeNormal) * 0.5) * tmp)
  newNode.halfWidth = newNode.radiusOrig * newNode.chordLength

  local newNodeLatPos
  if newNodeLaneConfig and #newNodeLaneConfig > 1 and newNode.nextNodeInPath and newNode.prevNodeInPath then -- TODO: error hits if the nextNode/prevNode conditions are not here
    local laneWidth = 2 * newNode.radiusOrig * (newNodeRangeRight - newNodeRangeLeft) / newNodeRangeLaneCount -- lane width not including chordLength
    local turnDir = (mapData.positions[newNode.nextNodeInPath] - newNode.posOrig) + (mapData.positions[newNode.prevNodeInPath] - newNode.posOrig)
    -- keep inside lanes narrower
    if turnDir:dot(newNode.normal) < 0 then
      newNodeLaneLimLeft = linearScale(newNodeRangeLeft, 0, 1, -newNode.halfWidth, newNode.halfWidth) + (bestLane - newNodeRangeLeftIdx) * laneWidth
      --[[ tighter outside left turns
      newNodeLaneLimLeft = -newNodeHalfWidth + (bestLane - 1) * laneWidth
      newNodeRangeLeft = min(newNodeRangeLeft, linearScale(-newNodeHalfWidth + (newNodeRangeLeftIdx - 1) * laneWidth, -newNodeHalfWidth, newNodeHalfWidth, 0, 1))
      --]]
      newNodeLaneLimRight = newNodeLaneLimLeft + laneWidth
      newNodeLatPos = (newNodeLaneLimLeft + newNodeLaneLimRight) * 0.5
      if bestLane == #newNodeLaneConfig then newNodeLaneLimRight = newNode.halfWidth end -- give remaining space on the right to the right most lane
    else
      newNodeLaneLimRight = linearScale(newNodeRangeRight, 0, 1, -newNode.halfWidth, newNode.halfWidth) - (newNodeRangeRightIdx - bestLane) * laneWidth
      newNodeLaneLimLeft = newNodeLaneLimRight - laneWidth
      newNodeLatPos = (newNodeLaneLimLeft + newNodeLaneLimRight) * 0.5
      if bestLane == 1 then newNodeLaneLimLeft = -newNode.halfWidth end -- give remaining space on the left to left most lane
    end
  else
    -- Transform newNode lateral position and lane limits from [0, 1] to [-r, r] using the recalculated newNodeHalfWidth
    newNodeLaneLimLeft = linearScale(newNodeLaneLimLeft, 0, 1, -newNode.halfWidth, newNode.halfWidth)
    newNodeLaneLimRight = linearScale(newNodeLaneLimRight, 0, 1, -newNode.halfWidth, newNode.halfWidth)
    newNodeLatPos = (newNodeLaneLimLeft + newNodeLaneLimRight) * 0.5
  end

  -- plan converges gradually towards the center of the road
  if not opt.driveInLaneFlag then
    -- normalized lateral xnorm of the last node on the plan
    local normalizedPrevLatXnorm = plan[plan.planCount].lateralXnorm / (plan[plan.planCount].halfWidth)

    -- last plan node lateral xnorm scaled to the width of the new node
    local lateralXnorm = max(min(normalizedPrevLatXnorm * newNode.halfWidth, newNode.halfWidth), -newNode.halfWidth)

    -- calculate smoothing parameter
    local t = min(1, max(0, plan.planLen / 100)) -- currently converges to the center of the road at 100m

    -- calculate desired lateral xnorm for the new plan node
    newNodeLatPos = lateralXnorm * (1 - t) + newNodeLatPos * t
  end

  newNode.pos = newNode.posOrig + newNodeLatPos * newNode.normal

  local lastPlanPos = plan[planCount] and plan[planCount].pos or ai.pos
  local vec = lastPlanPos - newNode.pos; vec.z = 0

  return {
    posOrig = newNode.posOrig,
    pos = newNode.pos,
    vec = vec,
    dirVec = vec:normalized(),
    turnDir = vec3(0,0,0),
    biNormal = newNode.biNormal,
    normal = newNode.normal,
    radiusOrig = newNode.radiusOrig,
    manSpeed = speedProfile and speedProfile[newNode.name],
    roadSpeedLimit = newNode.prevNodeInPath and mapData.graph[newNode.prevNodeInPath][newNode.name].speedLimit,
    pathidx = nextPathIdx,
    halfWidth = newNode.halfWidth,
    widthMarginOffset = 0,
    wayPointAhead = newNode.nextNodeInPath,
    laneLimLeft = newNodeLaneLimLeft, -- lateral coordinate of current lane left limit [-hW, hW]
    laneLimRight = newNodeLaneLimRight, -- lateral coordinate of current lane right limit [-hW, hW]
    curvature = 0,
    curvatureZ = 0,
    lateralXnorm = newNodeLatPos, -- lateral coordinate of pos [-hW, hW]
    legalSpeed = nil,
    speed = nil,
    inLaneConfig = newNode.inEdgeLanes, -- lane configuration of incoming edge to node
    rangeLeft = newNodeRangeLeft, -- lateral coordinate [0, 1] of the left hand side limit of the left most lane in the direction of travel
    rangeRight = newNodeRangeRight, -- lateral coordinate [0, 1] of the right hand side limit of the right most lane in the direction of travel
    rangeLaneCount = newNodeRangeLaneCount, -- number of contiguous lanes in the direction of travel counting from the current lane
    rangeBestLane = bestLane and newNodeRangeLeftIdx and (bestLane - newNodeRangeLeftIdx) or rangeBestLane, -- 0 indexed
    trafficSqVel = math.huge,
    dispDir = 0
  }
end

local function mergePathPrefix(source, dest, srcStart)
  srcStart = srcStart or 1
  local sourceCount = #source
  local dict = table.new(0, sourceCount-(srcStart-1))
  for i = srcStart, sourceCount do
    dict[source[i]] = i
  end

  local destCount = #dest
  for i = destCount, 1, -1 do
    local srci = dict[dest[i]]
    if srci ~= nil then
      local res = table.new(destCount, 0)
      local resi = 1
      for i1 = srcStart, srci - 1 do
        res[resi] = source[i1]
        resi = resi + 1
      end
      for i1 = i, destCount do
        res[resi] = dest[i1]
        resi = resi + 1
      end

      return res, srci
    end
  end

  return dest, 0
end

local function uniformPlanErrorDistribution(plan)
  if twt.state == 0 then
    local p1, p2 = plan[1].pos, plan[2].pos
    local dispVec = ai.pos - linePointFromXnorm(p1, p2, ai.pos:xnormOnLine(p1, p2))
    dispVec:setScaled(min(1, 4 * dt))
    local dispVecDir = dispVec:normalized()

    local tmpVec = p2 - p1; tmpVec:setCross(tmpVec, ai.upVec); tmpVec:normalize()
    --aiDeviation = dispVec:dot(tmpVec)

    local j = 0
    local dTotal = 0
    for i = 1, plan.planCount-1 do
      tmpVec:setSub2(plan[i+1].pos, plan[i].pos)
      if math.abs(dispVecDir:dot(tmpVec)) > 0.5 * plan[i].length then
        break
      end
      j = i
      dTotal = dTotal + plan[i].length
    end

    local sumLen = 0
    for i = j, 1, -1 do
      local n = plan[i]
      sumLen = sumLen + plan[i].length

      local lateralXnorm = n.lateralXnorm or 0
      local newLateralXnorm = clamp(lateralXnorm + ((dispVec):dot(n.normal) * sumLen / dTotal), n.laneLimLeft or -math.huge, n.laneLimRight or math.huge)
      tmpVec:setScaled2(n.normal, newLateralXnorm - lateralXnorm)
      n.pos:setAdd(tmpVec)
      n.lateralXnorm = newLateralXnorm

      plan[i+1].vec:setSub2(plan[i].pos, plan[i+1].pos); plan[i+1].vec.z = 0
      plan[i+1].dirVec:setScaled2(plan[i+1].vec, 1 / plan[i+1].vec:lengthGuarded())
    end

    updatePlanLen(plan, 1, j)
  end
end

local function createNewRoute(path)
  local newRoute = {
    path = path,
    plan = table.new(15, 10),
    laneChanges = {}, -- array: in the array each lane change is a dict with an idx key (path index at which lane change occurs) and a side key (direction of lane change)
    lastLaneChangeIdx = 1, -- path node up to which we have checked for a posible lane change
    pathLength = {0} -- distance from beggining of path to node at index i
  }
  newRoute.plan.stopSeg = math.huge

  return newRoute
end

local function isVehicleStopped(v)
  if v.isParked then
    return true
  elseif v.states.ignitionLevel == 0 or v.states.ignitionLevel == 1 then
    return true
  elseif v.states.hazard_enabled == 1 and v.vel:squaredLength() < 9 then
    return true
  end
  return false
end

local function inCurvature(v1, v2)
  --[[
    Given three points A, B, C (with AB being the vector from A to B), the curvature (= 1 / radius)
    of the circle going through them is:

    curvature = 2 * (AB x BC) / ( |AB| * |BC| * |CA| ) =>
              = 2 * |AB| * |BC| * Sin(th) / ( |AB| * |BC| * |CA| ) =>
              = 2 * (+/-) * sqrt ( 1 - Cos^2(th) ) / |CA| =>
              = 2 * (+/-) sqrt [ ( 1 - Cos^2(th) ) / |CA|^2 ) ] -- This is an sqrt optimization step

    In the calculation below the (+/-) which indicates the turning direction (direction of AB x BC) has been dropped
  --]]

  -- v1 and v2 vector components
  local v1x, v1y, v1z, v2x, v2y, v2z = v1.x, v1.y, v1.z, v2.x, v2.y, v2.z

  local v1Sqlen, v2Sqlen = v1x * v1x + v1y * v1y + v1z * v1z, v2x * v2x + v2y * v2y + v2z * v2z
  local dot12 = v1x * v2x + v1y * v2y + v1z * v2z
  local cosSq = min(1, dot12 * dot12 / max(1e-30, v1Sqlen * v2Sqlen))

  if dot12 < 0 then -- angle between the two segments is > 90 deg
    local minDsq = min(v1Sqlen, v2Sqlen)
    local maxDsq = minDsq / max(1e-30, cosSq)
    if max(v1Sqlen, v2Sqlen) > (minDsq + maxDsq) * 0.5 then
      if v1Sqlen > v2Sqlen then
        -- swap v1 and v2
        v1x, v1y, v1z, v2x, v2y, v2z = v2x, v2y, v2z, v1x, v1y, v1z
        v1Sqlen, v2Sqlen = v2Sqlen, v1Sqlen
      end
      local s = sqrt(0.5 * (minDsq + maxDsq) / max(1e-30, v2Sqlen))
      v2x, v2y, v2z = s * v2x, s * v2y, s * v2z
    end
  end

  return 2 * sqrt((1 - cosSq) / max(1e-30, square(v1x + v2x) + square(v1y + v2y) + square(v1z + v2z))) -- the denominator is v1:squaredLength(-v2)
end

-- ********* FUNCTIONS FOR SPEED PROFILE GENERATION ********* --

-- Computes the acceleration budget based on the vehicle speed (x) to simulate more realistic real world driving behaviour
-- https://arxiv.org/pdf/1907.01747
local function speedBasedAccelBudget(x, a)
  x = max(0, x)
  a = a or 0

  local fx
  if 0 <= x and x < 5 then
    fx = 0.3 * x + 4
  elseif 5 <= x and x < 10 then
    fx = 5.5
  elseif 10 <= x and x < 15 then
    fx = -0.1 * x + 6.5
  elseif 15 <= x and x < 20 then
    fx = -0.15 * x + 7.25
  elseif 20 <= x and x < 25 then
    fx = -0.15 * x + 7.25
  elseif 25 <= x and x < 30 then
    fx = -0.1 * x + 6
  else
    fx = 3
  end

  return max(0, min(fx + a, ai.staticFrictionCoef * g))
end

local speedProfileMode -- ('Back' for new backward method, 'ForwBack' for forward+Backward method)
local function setSpeedProfileMode(mode)
  if mode == 'Back' then
    speedProfileMode = 'Back'
  elseif mode == 'ForwBack' then
    speedProfileMode = 'ForwBack'
  else
    speedProfileMode = nil
  end
end

-- Compute maximum available longitudinal acceleration
local function acc_eval_1(speedSq, acc_max, curvature)
  local ax_max_tyre = acc_max -- has to be exctracted from ggv
  local ay_max_tyre = acc_max -- has to be exctracted from ggv
  local ay_used = speedSq * curvature
  return ax_max_tyre * max(0, 1 - ay_used / ay_max_tyre)
end

local function acc_eval_2(speedSq, acc_max, curvature)
  local ax_max_tyre = acc_max -- has to be exctracted from ggv
  local ay_max_tyre = acc_max -- has to be exctracted from ggv
  local ay_used = speedSq * curvature
  if ay_used < ay_max_tyre then
    return ax_max_tyre * sqrt(1 - square(ay_used/ay_max_tyre))
  else
    return 0
  end
end

local acc_eval = acc_eval_2 -- Default adherence constraint
-- set the index for adherence constraint, useful only for Back or ForwBack mode
local function setTractionModel(model_index)
  if model_index == 1 then
    acc_eval = acc_eval_1
  else
    acc_eval = acc_eval_2
  end
end

-- Compute forward pass (speed0 = starting velocity, model_index = index for adherence constraint)
local function solver_f_acc_profile(plan, speed0)
  -- Note: This calculation need the node speed values to be squared.
  -- This will already be the case if the previous calculation for the limiting turn speed avoided calculating square root of speeds.

  plan[1].speed = speed0 or plan[1].speed

  -- The last node speed value was not calculated from the limiting turn speed (due to absence of curvature value), so square it.
  plan[plan.planCount].speed = square(plan[plan.planCount].speed)

  for i = 1, plan.planCount-1 do
    local n1, n2 = plan[i], plan[i+1]

    local vx_possible_next
    if plan.stopSeg <= i+1 then
      vx_possible_next = 0
    else
      if min(n2.speed, n2.trafficSqVel) < n1.speed then -- max velocity at i-1 is less than velocity at i (not a deceleration phase)
        vx_possible_next = min(n2.speed, n2.trafficSqVel)
      else
        local ax_final = acc_eval(n1.speed, n1.acc_max, abs(n1.curvature))
        vx_possible_next = n1.speed + 2 * ax_final * n1.length -- speed squared
        vx_possible_next = min(n2.speed, min(n2.trafficSqVel, vx_possible_next))
      end
    end

    n2.speed = vx_possible_next
  end

  -- Backwards aceel integrator expects the last node speed value to not be squared
  plan[plan.planCount].speed = sqrt(plan[plan.planCount].speed)
end

-- Compute backward pass (speed_end = final velocity, model_index = index for adherence constraint)
local function solver_b_acc_profile(plan)
  for i = plan.planCount, 2, -1 do
    local n1, n2 = plan[i-1], plan[i]
    local vx_possible_next
    if plan.stopSeg <= i-1 then
      vx_possible_next = 0
    else
      local n2SpeedSq = n2.speed * n2.speed
      if min(n1.speed, n1.trafficSqVel) < n2SpeedSq then -- max velocity at i-1 is less than velocity at i (not a deceleration phase)
        vx_possible_next = sqrt(min(n1.speed, n1.trafficSqVel))
      else
        -- available longitudinal acceleration at node i
        local ax_possible_current = acc_eval(n2SpeedSq, n2.acc_max, abs(n2.curvature))
        -- possible velocity at node i-1 given available longitudinal acceleration at node i
        vx_possible_next = n2SpeedSq + 2 * n1.length * ax_possible_current

        -- available longitudinal acceleration at node i-1 given velocity estimate at node i-1
        local ax_possible_next = acc_eval(vx_possible_next, n1.acc_max, abs(n1.curvature))
        -- possible velocity at i-1 given available longitudinal acceleration at node i-1
        local vx_tmp = n2SpeedSq + 2 * n1.length * ax_possible_next

        if vx_possible_next > vx_tmp then
          -- available longitudinal acceleration at node i-1 given new velocity estimate at node i-1
          ax_possible_next = acc_eval(vx_tmp, n1.acc_max, abs(n1.curvature))
          -- improve velocity estimate at i-1 given available longitudinal acceleration at node i-1
          vx_tmp = n2SpeedSq + 2 * n1.length * ax_possible_next
          -- keep the velocity that satisfies longitudinal acceleration constraints at node i-1 and node i
          vx_possible_next = min(vx_possible_next, vx_tmp)
        end

        vx_possible_next = sqrt(min(n1.speed, min(n1.trafficSqVel, vx_possible_next))) -- respect traffic speed
      end
    end

    n1.speed = n1.manSpeed or
               (M.speedMode == 'limit' and M.routeSpeed and min(M.routeSpeed, vx_possible_next)) or
               (M.speedMode == 'set' and M.routeSpeed) or
               vx_possible_next

    if M.speedMode == 'legal' then
      n2.legalSpeed = n2.legalSpeed or n2.speed
      n1.legalSpeed = min(min(n1.speed, sqrt(n2.legalSpeed * n2.legalSpeed + (n1.acc_max + n2.acc_max) * n1.length)), (n1.roadSpeedLimit or math.huge))
    end

    n1.trafficSqVel = math.huge
  end
end

local function setRacing(v)
  if v == true then
    opt.racing = true
    traffic.filtered = false
  else
    opt.racing = false
  end
end
M.setRacing = setRacing

local function setTrafficFilter(v)
  if v == true then
    traffic.filtered = true
  else
    traffic.filtered = false
  end
end
M.setTrafficFilter = setTrafficFilter

local function setVdraw(v)
  if v == true then
    traffic.vdraw = true
  else
    traffic.vdraw = false
  end
end
M.setVdraw = setVdraw

local function trafficFilter(index, route, v, draw)
  local path = route.path
  local plan1 = route.plan[1]
  local plan2 = route.plan[2]
  --local ai2vmiddle =  ai.pos:squaredDistance(v.posMiddle)

  -- Initialize n1 node data table
  local n1 = {name = nil, posOrig = plan1.posOrig, radiusOrig = plan1.radiusOrig, biNormal = plan1.biNormal, normal = vec3()}

  -- Initialize n2 node data table
  local n2 = {normal = vec3()}

  -- placeholder for segment direction vector
  local dirVec, dirVecNext = vec3(), vec3()

  -- cache player vehicle position and direction data
  local vPfront, vPrear, vPmiddle, vdirVec = v.posFront, v.posRear, v.posMiddle, v.dirVec

  -- will be set to true if any of the path nodes is an intersection
  local intersectionFound = false
  for i = max(index.start, plan2.pathidx), index.final do
    -- check if this node is an intersection
    intersectionFound = intersectionFound or tableSize(mapData.graph[route.path[i]]) > 2

    -- gather data on node n2
    n2.name = path[i]
    n2.posOrig = getPathNodePosition(route, i)
    n2.radiusOrig = getPathNodeRadius(path, i) --mapData.radius[path[i]],
    n2.biNormal = -mapmgr.surfaceNormalBelow(mapData.positions[path[i]], mapData.radius[path[i]] * 0.5)

    dirVec:setSub2(n1.posOrig, n2.posOrig); dirVec.z = 0; dirVec:normalize()
    n1.normal:setCross(dirVec, n1.biNormal)
    n2.normal:setCross(dirVec, n2.biNormal)

    local roadHalfWidth1, roadHalfWidth2 =  n1.radiusOrig * 1.05, n2.radiusOrig * 1.05

    -- n1 and n2 left boundaries
    local n1PosLeft, n2PosLeft = n1.posOrig - roadHalfWidth1 * n1.normal, n2.posOrig - roadHalfWidth2 * n2.normal

    -- n1 and n2 right boundaries
    local n1PosRight, n2PosRight = n1.posOrig + roadHalfWidth1 * n1.normal, n2.posOrig + roadHalfWidth2 * n2.normal

    -- projection of vehicle front position on line passing through right boundaries
    local xnormFrRight = vPfront:xnormOnLine(n1PosRight, n2PosRight)

    -- projection of vehicle front position on line passing through left boundaries
    local xnormFrLeft = vPfront:xnormOnLine(n1PosLeft, n2PosLeft)

    -- projection of vehicle rear position on line passing through right boundaries
    local xnormReRight = vPrear:xnormOnLine(n1PosRight, n2PosRight)

    -- projection of vehicle rear position on line passing through left boundaries
    local xnormReLeft = vPrear:xnormOnLine(n1PosLeft, n2PosLeft)

    -- taking the nearest projection of vehicle front and rear
    local minF = min(xnormFrRight, xnormFrLeft)
    local minR = min(xnormReRight, xnormReLeft)

    -- ai to vehicle direction vector
    local ai2PlVec = vPfront - ai.pos; ai2PlVec:normalize()

    local ai2v = vPmiddle:squaredDistance(ai.pos - 0.5 * ai.length * ai.dirVec)
    local xnormV = vPmiddle:xnormOnLine(plan1.posOrig - roadHalfWidth1 * plan1.normal, plan1.posOrig + roadHalfWidth1 * plan1.normal)
    local lanew = (plan1.rangeRight - plan1.rangeLeft)/plan1.rangeLaneCount
    if plan1.rangeLaneCount > 1 and ai.dirVec:dot(vdirVec) > 0.7 and ai2v < square((1.2*ai.length + 1.2*v.length)) and (xnormV > plan1.rangeLeft and xnormV < plan1.rangeRight) and (not (xnormV > (plan1.rangeLeft + lanew*plan1.rangeBestLane) and xnormV < (plan1.rangeLeft + lanew*(plan1.rangeBestLane+1)))) then
      if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(0,0,0,160)) end
      if ai2PlVec:dot(ai.rightVec) > 0 then
        ai.ghostR = true
      else
        ai.ghostL = true
      end
      return true
    end

    -- *Check 1.1: check if v-vehicle is in the current path-segment projection
    if (minF > 0 and minF < 1) or (minR > 0 and minR < 1) then
      -- *Check 1.1.1: check if v-vehicle is coming in opposite direction
      if ai2PlVec:dot(vdirVec) < 0 then
        -- smooth transition of dirVec if mesh is not large enough
        if minF < 1 and minR > 1 and path[i+1] then
          local n3posOrig = getPathNodePosition(route, i+1)
          dirVecNext:setSub2(n2.posOrig, n3posOrig); dirVecNext.z = 0; dirVecNext:normalize()
          dirVec:setAdd2(max(0,minF)*dirVecNext, max(0,1-minF)*dirVec)
          --dirVec:setAdd(dirVecNext)
          dirVec:normalize()
        end
        -- *Check 1.1.1.1: add it if it is not parallel to current path-segment
        if vdirVec:dot(dirVec) < 0.95 then
          if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(255, 0, 0, 160)) end
          return true
        -- *Check 1.1.1.2: add it if it is parallel to current path-segment but there is an intersection
        else
          if traffic.intersection and intersectionFound then
            if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(255, 100, 0, 160)) end
            return true
          end
        end
      -- *Check 1.1.2: add v-vehicle if it is in front of us
      else
        v.noproj = true
        if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(0, 255, 0, 160)) end
        return true
      end
      -- *Check 1.1.3: check for v-vehicles that are coming in opposite direction and are in our lanes
      local xnormP = vPfront:xnormOnLine(n1PosLeft, n1PosRight)
      local rangeLeft, rangeRight = plan1.rangeLeft, plan1.rangeRight
      if n1.name then
        local lanes = getEdgeLaneConfig(n1.name, n2.name)
        rangeLeft, rangeRight = laneRange(lanes)
      end
      if xnormP > rangeLeft and xnormP < rangeRight then
        if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(255, 255, 255, 160)) end
        return true
      else
        return false
      end
    -- *Check 1.2: add v-vehicles if it is behind us or in an dead corner (due to path projection)
    elseif xnormFrRight < 0 or xnormFrLeft < 0 then
      if vPfront:squaredDistance(n1.posOrig) < 100 * 100 then
        if draw then obj.debugDrawProxy:drawSphere(2, vPfront, color(0, 0, 255, 160)) end
        return true
      end
    end

    -- update n1 data
    n1.name, n1.posOrig, n1.radiusOrig, n1.biNormal = n2.name, n2.posOrig, n2.radiusOrig, n2.biNormal
  end

  return false
end

local function trafficFilter_2(route, v)
  local path = route.path
  local curPlanIdx = route.plan[2].pathidx
  local pathCount = #path
  local frontChecks, rearChecks = nil, nil
  for i = 1, pathCount-1 do

    if i >= curPlanIdx then
      if tableSize(mapData.graph[path[i]]) > 2 then
        return true
      end
    end

    local pos1, pos2 = mapData:getEdgePositions(path[i], path[i+1])
    local rad1, rad2 = mapData:getEdgeRadii(path[i], path[i+1])
    local biNormal = mapmgr.surfaceNormalBelow(pos1)
    local normal = (pos2-pos1):cross(biNormal); normal:normalize()
    local laneConfig = getEdgeLaneConfig(path[i], path[i+1])
    local laneRangeLimLeft, laneRangeLimRight = laneRange(laneConfig)

    if not frontChecks then
      local longXnormFront = v.posFront:xnormOnLine(pos1, pos2)
      local latXnormFront = v.posFront:xnormOnLine(pos1, pos1 + normal * (rad1 + (rad2 - rad1) * clamp(longXnormFront, 0, 1)))
      latXnormFront = (latXnormFront + 1) * 0.5 -- maps [-1, 1] interval to [0, 1] interval
      if longXnormFront >= 0 and longXnormFront <= 1 and latXnormFront >= 0 and latXnormFront <= laneRangeLimLeft then
        frontChecks = i
      end
    end

    if not rearChecks then
      local longXnormRear = v.posRear:xnormOnLine(pos1, pos2)
      local latXnormRear = v.posRear:xnormOnLine(pos1, pos1 + normal * (rad1 + (rad2 - rad1) * clamp(longXnormRear, 0, 1)))
      latXnormRear = (latXnormRear + 1) * 0.5 -- maps [-1, 1] interval to [0, 1] interval
      if longXnormRear >= 0 and longXnormRear <= 1 and latXnormRear >= 0 and latXnormRear <= laneRangeLimLeft then
        rearChecks = i
      end
    end

    if frontChecks and rearChecks then
      return false
    end


  end

  return true
end

local function updatePlanbestRange(plan)
  for i = 1, plan.planCount do
    local n = plan[i]
    local roadHalfWidth = n.halfWidth
    local laneWidth = 2 * roadHalfWidth * (n.rangeRight - n.rangeLeft) / n.rangeLaneCount
    plan[i].rangeBestLane = clamp((n.laneLimLeft - ((2 * n.rangeLeft - 1) * roadHalfWidth)) / laneWidth, 0, n.rangeLaneCount-1)
    --print(plan[i].rangeBestLane)
  end
end

local function calculateTrafficTargetSpeed(plan, trafficTable, trafficTableLen)
  plan.trafficTargetSpeed = math.huge
  if trafficTableLen > 0 and plan.targetSpeed > 0 then
    local distOnPlan = - plan[1].length * plan.aiXnormOnSeg -- 0
    local segDirVec, segVx, segC, segVz, segVy = vec3(), vec3(), vec3(), vec3(), vec3()
    for i = 1, plan.planCount-1 do
      local n1, n2 = plan[i], plan[i+1]
      distOnPlan = distOnPlan + n1.length -- distance from the ai vehicle front position to the end of the ith segment along the plan
      segDirVec:setSub2(n2.pos, n1.pos); segDirVec:setScaled(1 / (n1.length + 1e-30))

      -- Bounding box of segment [n1, n2]
      segVx:setScaled2(segDirVec, 0.5 * n1.length)
      segC:setAdd2(n1.pos, segVx)
      segVz = mapmgr.surfaceNormalBelow(segC, (n1.radiusOrig + n2.radiusOrig) * 0.25); segVz:setScaled(-1)
      segVy:setCross(segVz, segVx); segVy:setScaled(0.5 * ai.width / (segVy:length() +  1e-30)) -- 0.5 * (ai.width + 1)
      segVy:setScaled2(segVz:cross(segVx):normalized(), 0.5 * ai.width)

      for j = trafficTableLen, 1, -1 do
        local v = trafficTable[j]
        v.posMiddle, v.vx, v.vy, v.vz = getObjectBoundingBox(v.id)
        v.posFront = v.posMiddle + v.vx
        v.posRear = v.posMiddle - v.vx
        v.dirVec = v.vx:normalized()
        v.length = v.vx:length() * 2
        v.width = v.vy:length() * 2

        if overlapsOBB_OBB(v.posMiddle, v.vx, v.vy, v.vz, segC, segVx, segVy, segVz) then
          local vRearXnorm, vFrontXnorm = v.posRear:xnormOnLine(n1.pos, n2.pos), v.posFront:xnormOnLine(n1.pos, n2.pos)
          -- if the vehicle overlaps the first segment check if its xnorm is greater than the xnorm of the ai vehicle
          if i > 1 or max(vRearXnorm, vFrontXnorm) > plan.aiXnormOnSeg then
            local vXnorm = clamp(min(vRearXnorm, vFrontXnorm), 0, 1)

            --local ai2PlDist = max(0, distOnPlan - plan[1].length * plan.aiXnormOnSeg + clamp(vXnorm, 0, 1) * n1.length) -- if current segment length is added after the traffic table loop

            -- the ai.speed term creates a feedback loop
            -- lowering the coefficient of that term mitigates the effect of the feedback loop
            -- parts of the throttle/brake/handbrake control logic at the end of driveToTarget also seem to be creating issues when at low targetSpeed
            -- see function driveToTarget: TODO: handbrake when stoped or moving backward and TODO: handbrake when turning
            local ai2PlDist = max(0, distOnPlan - (1 - vXnorm) * n1.length) - max(2.5, ai.speed * 1)

            local velProjOnSeg = v.vel:dot(segDirVec) -- max(0, v.vel:dot(segDirVec))

            --dump('dist and vel on seg', ai2PlDist, velProjOnSeg)

            local targetSpeed = max(0, abs(velProjOnSeg) * velProjOnSeg + 2 * g * min(aggression, ai.staticFrictionCoef) * ai2PlDist)

            -- might help improve the throttle/brake input stability caused by the feedback loop of the ai.speed term in ai2PlDist
            --if plan.trafficTargetSpeed < 0.25 then plan.trafficTargetSpeed = 0 end

            plan.trafficTargetSpeed = min(targetSpeed, plan.trafficTargetSpeed)
            plan.trafficMinProjSpeed = min(plan.trafficMinProjSpeed, velProjOnSeg)
          end

          table.remove(trafficTable, j)
          trafficTableLen = trafficTableLen - 1
        end

        if plan.trafficTargetSpeed == 0 then break end
      end

      --distOnPlan = distOnPlan + n1.length -- distance to the end of the ith segment

      if trafficTableLen == 0 or plan.trafficTargetSpeed == 0 then -- or ai.speed * ai.speed < 2 * distOnPlan * (0.2 * ai.staticFrictionCoef * g)
        break
      end
    end
  end

  plan.trafficTargetSpeed = sqrt(plan.trafficTargetSpeed) -- plan.trafficTargetSpeedSmoother:get(sqrt(plan.trafficTargetSpeed), dt)
end


local function planAhead(route, baseRoute)
  if not route then return end

  if not route.path then
    route = createNewRoute(route)
  end

  local plan = route.plan

  if baseRoute and not plan[1] then
    -- merge from base plan
    local bsrPlan = baseRoute.plan
    if bsrPlan[2] then
      local commonPathEnd
      route.path, commonPathEnd = mergePathPrefix(baseRoute.path, route.path, bsrPlan[2].pathidx)
      route.lastLaneChangeIdx = 2
      table.clear(route.laneChanges)
      route.pathLength = {0}
      if commonPathEnd >= 1 then
        local refpathidx = bsrPlan[2].pathidx - 1
        local planLen, planCount = 0, 0
        for i = 1, #bsrPlan do
          local n = bsrPlan[i]
          if n.pathidx > commonPathEnd then break end
          planLen = planLen + (n.length or 0)
          planCount = i

          plan[i] = {
            posOrig = vec3(n.posOrig),
            pos = vec3(n.pos),
            vec = vec3(n.vec),
            dirVec = vec3(n.dirVec),
            turnDir = vec3(n.turnDir),
            biNormal = vec3(n.biNormal),
            normal = vec3(n.normal),
            radiusOrig = n.radiusOrig,
            pathidx = max(1, n.pathidx-refpathidx),
            roadSpeedLimit = n.roadSpeedLimit,
            halfWidth = n.halfWidth,
            widthMarginOffset = n.widthMarginOffset,
            wayPointAhead = n.wayPointAhead,
            length = n.length,
            curvature = n.curvature,
            curvatureZ = n.curvatureZ,
            lateralXnorm = n.lateralXnorm,
            laneLimLeft = n.laneLimLeft,
            laneLimRight = n.laneLimRight,
            legalSpeed = nil,
            speed = nil,
            rangeLeft = n.rangeLeft,
            rangeRight = n.rangeRight,
            rangeLaneCount = n.rangeLaneCount,
            rangeBestLane = n.rangeBestLane,
            trafficSqVel = math.huge,
            dispDir = n.dispDir
          }
        end
        plan.planLen = planLen
        plan.planCount = planCount
        plan.aiDeviation = 0
        if plan[bsrPlan.targetSeg+1] then
          plan.targetSeg = bsrPlan.targetSeg
          plan.targetPos = vec3(bsrPlan.targetPos)
          plan.aiSeg = bsrPlan.aiSeg
          plan.aiXnormOnSeg = bsrPlan.aiXnormOnSeg
        end
      end
    end
  end

  if not plan[1] then
    local posOrig = vec3(ai.pos)
    local radiusOrig = 2
    local normal = vec3(0, 0, 0)
    local latXnorm = 0
    local rangeLeft, rangeRight, rangeBestLane = 0, 1, 0
    local laneLimLeft, laneLimRight = -ai.width * 0.5, ai.width * 0.5
    local biNormal = mapmgr.surfaceNormalBelow(ai.pos, ai.width * 0.5); biNormal:setScaled(-1)
    local wp, lanes, roadSpeedLimit
    if ai.currentSegment[1] and ai.currentSegment[2] then
      local wp1 = route.path[1]
      local wp2
      if wp1 == ai.currentSegment[1] then
        wp2 = ai.currentSegment[2]
      elseif wp1 == ai.currentSegment[2] then
        wp2 = ai.currentSegment[1]
      end
      if wp2 and route.path[2] ~= wp2 then
        -- local pos1 = mapData.positions[wp1]
        -- local pos2 = mapData.positions[wp2]
        local pos1, pos2 = mapData:getEdgePositions(wp1, wp2)
        local xnorm = ai.pos:xnormOnLine(pos2, pos1)
        if xnorm >= 0 and xnorm <= 1 then
          local rad1, rad2 = mapData:getEdgeRadii(wp1, wp2)
          local rad = lerp(rad2, rad1, xnorm)
          posOrig = linePointFromXnorm(pos2, pos1, xnorm)
          normal:setCross(biNormal, pos1 - pos2); normal:normalize()
          radiusOrig = rad
          wp = wp2
          roadSpeedLimit = mapData.graph[wp1][wp2].speedLimit
          latXnorm = ai.pos:xnormOnLine(posOrig, posOrig + normal)
          laneLimLeft = latXnorm - ai.width * 0.5 -- TODO: rethink the limits here
          laneLimRight = latXnorm + ai.width * 0.5
          if opt.driveInLaneFlag then
            lanes = getEdgeLaneConfig(wp2, wp1)
            rangeLeft, rangeRight = laneRange(lanes)

            local normalizedLatXnorm = (latXnorm / radiusOrig + 1) * 0.5
            local normalizedLaneLimLeft = (laneLimLeft / radiusOrig + 1) * 0.5
            local normalizedLaneLimRight = (laneLimRight / radiusOrig + 1) * 0.5

            local bestLane
            bestLane, normalizedLaneLimLeft, normalizedLaneLimRight = getBestLane(lanes, normalizedLatXnorm, normalizedLaneLimLeft, normalizedLaneLimRight)

            local _, _, rangeLeftIdx, rangeRightIdx = getLaneRangeFromLane(lanes, bestLane)
            rangeBestLane = bestLane - rangeLeftIdx -- bestLane - rangeRightIdx

            laneLimLeft = (normalizedLaneLimLeft * 2 - 1) * radiusOrig
            laneLimRight = (normalizedLaneLimRight * 2 - 1) * radiusOrig
            latXnorm = (laneLimLeft + laneLimRight) * 0.5
          end
        end
      end
    end

    local rangeLaneCount = lanes and numOfLanesInDirection(lanes, "+") or 1 -- numOfLanesFromRadius(radiusOrig)
    local vec = vec3(-8 * ai.dirVec.x, -8 * ai.dirVec.y, 0)

    plan[1] = {
      posOrig = posOrig,
      pos = vec3(ai.pos),
      vec = vec,
      dirVec = vec:normalized(),
      turnDir = vec3(0,0,0),
      biNormal = biNormal,
      normal = normal,
      radiusOrig = radiusOrig,
      widthMarginOffset = 0,
      length = 0,
      curvature = 0,
      curvatureZ = 0,
      halfWidth = radiusOrig,
      lateralXnorm = latXnorm,
      laneLimLeft = laneLimLeft,
      laneLimRight = laneLimRight,
      rangeLeft = rangeLeft,
      rangeRight = rangeRight,
      rangeLaneCount = rangeLaneCount,
      rangeBestLane = rangeBestLane,
      pathidx = nil,
      roadSpeedLimit = roadSpeedLimit,
      legalSpeed = nil,
      speed = nil,
      wp = wp,
      trafficSqVel = math.huge,
      dispDir = 0
    }

    plan.planCount = 1
    plan.planLen = 0
    plan.aiXnormOnSeg = 0
    plan.aiDeviation = 0
  end

  local minPlanLen
  if M.mode == 'traffic' then
    minPlanLen = getMinPlanLen(20, ai.speed, 0.2 * ai.staticFrictionCoef) -- 0.25 * min(aggression, ai.staticFrictionCoef)
  else
    minPlanLen = getMinPlanLen(40)
  end

  --profilerPushEvent("ai_buildPlan")
  while not plan[MIN_PLAN_COUNT] or (plan.planLen - (plan.aiXnormOnSeg or 0) * plan[1].length) < minPlanLen do -- TODO: (plan.planLen < minPlanLen and plan.stopSeg + 1 == plan.planCount)
    local n = buildNextRoute(route)
    if not n then break end
    plan.planCount = plan.planCount + 1
    plan[plan.planCount] = n
    plan[plan.planCount-1].length = n.pos:distance(plan[plan.planCount-1].pos)
    plan.planLen = plan.planLen + plan[plan.planCount-1].length
  end
  --profilerPopEvent("ai_buildPlan")

  if not plan[2] then return end
  if not plan[1].pathidx then
    plan[1].pathidx = plan[2].pathidx
    plan[1].roadSpeedLimit = plan[2].roadSpeedLimit
  end

  -- Calculate the length of the path at each path node one segment per call of planAhead
  if not route.pathLength[#route.path] then
    local n = #route.pathLength
    table.insert(
      route.pathLength,
      mapData.positions[route.path[n+1]]:distance(mapData.positions[route.path[max(1, n)]]) + route.pathLength[n]
    )
  end

  -- check path node at lastLaneChangeIdx for a possible lane change
  --profilerPushEvent("ai_find_LaneChanges")
  if route.lastLaneChangeIdx < #route.path then
    local wp1, wp2
    if route.lastLaneChangeIdx == 1 then
      wp2 = route.path[route.lastLaneChangeIdx]
      if plan[1].wp and (plan[1].wp ~= wp2) then
        wp1 = plan[1].wp
      else
        --wp1 not found: safeguard
        route.lastLaneChangeIdx = 2
        wp1, wp2 = route.path[route.lastLaneChangeIdx-1], route.path[route.lastLaneChangeIdx]
      end
    else
      wp1, wp2 = route.path[route.lastLaneChangeIdx-1], route.path[route.lastLaneChangeIdx]
    end
    if route.lastLaneChangeIdx < #route.path then
      if numOfLanesInDirection(getEdgeLaneConfig(wp1, wp2), '+') > 1 then
        local minNode = roadNaturalContinuation(wp1, wp2)
        local wp3 = route.path[route.lastLaneChangeIdx+1]
        if minNode and minNode ~= wp3 then -- road natural continuation at wp2 is not in our path
          local minNodePos, wp2Pos_2 = mapData:getEdgePositions(minNode, wp2)
          local minNodeEdgeVec = minNodePos - wp2Pos_2
          local wp1Pos, wp2Pos_1 = mapData:getEdgePositions(wp1, wp2)
          local wp1TOwp2EdgeVec = wp2Pos_1 - wp1Pos
          if minNodeEdgeVec:dot(wp1TOwp2EdgeVec) > 0 then -- road natural continuation is up to 90 deg
            local edgeNormal = gravityDir:cross(minNodePos - wp2Pos_2):normalized()
            local wp3Pos = mapData:getEdgePositions(wp3, wp2)
            local side = sign2(edgeNormal:dot(wp3Pos) - edgeNormal:dot(minNodePos))
            table.insert(route.laneChanges, {pathIdx = route.lastLaneChangeIdx, side = side, alternate = minNode})
          end
        end
      end
      route.lastLaneChangeIdx = route.lastLaneChangeIdx + 1
    end
  end
  --profilerPopEvent("ai_find_LaneChanges")

  local distOnPlan = 0
  --profilerPushEvent("ai_trajectory_splitting")
  for i = 1, plan.planCount-1 do
    local segLenSq = plan[i].posOrig:squaredDistance(plan[i+1].posOrig)
    local xSq = square(distOnPlan)
    if min(segLenSq, square(plan[i].length)) > square(min(220, (25e-8 * xSq + 1e-5) * xSq + 6)) and distOnPlan < 550 then
      local n1, n2 = plan[i], plan[i+1]

      local posOrig = n1.posOrig + n2.posOrig; posOrig:setScaled(0.5)
      local radiusOrig = (n1.radiusOrig + n2.radiusOrig) * 0.5 -- TODO: this might be inacurate since posOrig might not be halfway between n1.posOrig and n2.posOrig

      local biNormal = mapmgr.surfaceNormalBelow(posOrig, radiusOrig * 0.5); biNormal:setScaled(-1)

      -- Interpolated normals
      local normal = vec3()
      if segLenSq > square(2 * radiusOrig + n1.radiusOrig + n2.radiusOrig) then
        -- calculate normal from the direction vector of edge (i, i+1)
        normal:setSub2(plan[i+1].pos, plan[i].pos)
        normal:setCross(biNormal, normal)
        normal:normalize()
      else
        -- calculate from adjacent normals
        local norm1 = plan[i].normal:cross(biNormal)
        norm1:setCross(biNormal, norm1); norm1:normalize()
        local norm2 = plan[i+1].normal:cross(biNormal)
        norm2:setCross(biNormal, norm2); norm2:normalize()
        normal:setAdd2(norm1, norm2)
        normal:setScaled(1 / (normal:length() + 1e-30))
      end

      local pos = n1.pos + n2.pos; pos:setScaled(0.5)
      local vec = n1.pos - pos; vec.z = 0
      local dirVec = vec:normalized()

      local _, t2 = closestLinePoints(pos, pos + normal, n1.posOrig, n2.posOrig)
      posOrig = linePointFromXnorm(n1.posOrig, n2.posOrig, t2)
      local edgeNormal = biNormal:cross(n2.posOrig - n1.posOrig); edgeNormal:normalize()
      local _, t2 = closestLinePoints(posOrig, posOrig + normal, plan[i].posOrig + plan[i].radiusOrig * edgeNormal, plan[i+1].posOrig + plan[i+1].radiusOrig * edgeNormal)
      local limPos = linePointFromXnorm(plan[i].posOrig + plan[i].radiusOrig * edgeNormal, plan[i+1].posOrig + plan[i+1].radiusOrig * edgeNormal, max(0, min(1, t2)))
      local roadHalfWidth = posOrig:distance(limPos)
      local lateralXnorm = pos:xnormOnLine(posOrig, limPos) * roadHalfWidth -- [-r, r]

      n1.length = n1.length * 0.5

      n2.vec:set(vec)
      n2.dirVec:set(dirVec)

      --local laneLimLeft = (n1.laneLimLeft / (n1.radiusOrig * n1.chordLength) + n2.laneLimLeft / (n2.radiusOrig * n2.chordLength)) * 0.5 * roadHalfWidth
      --local laneLimRight = (n1.laneLimRight / (n1.radiusOrig * n1.chordLength) + n2.laneLimRight / (n2.radiusOrig * n2.chordLength)) * 0.5 * roadHalfWidth

      local rangeLeft = (n1.rangeLeft + n2.rangeLeft) * 0.5 -- lane range left boundary lateral coordinate in [0, 1]. 0 is left road boundary: always 0 when driveInLane is off
      local rangeRight = (n1.rangeRight + n2.rangeRight) * 0.5 -- lane range right boundary lateral coordinate in [0, 1]. 1 is right road boundary: always 1 when driveInLane is off
      local rangeLaneCount = (n1.rangeLaneCount + n2.rangeLaneCount) * 0.5 -- number of lanes in the range: always 1 when driveInLane is off

      local laneWidth = (rangeRight - rangeLeft) / rangeLaneCount -- self explanatory: entire width of the road when driveInLane is off i.e. 1
      local rangeBestLane = (n1.rangeBestLane + n2.rangeBestLane) * 0.5 -- best lane in the range: only one lane to pick from when driveInLane is off

      local laneLimLeft = linearScale(rangeLeft + rangeBestLane * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth) -- lateral coordinate of left boundary of lane rescaled to the road half width
      local laneLimRight = linearScale(rangeLeft + (rangeBestLane + 1) * laneWidth, 0, 1, -roadHalfWidth, roadHalfWidth) -- lateral coordinate of right boundary of lane rescaled to the road half width

      local roadSpeedLimit
      if n2.pathidx > 1 then
        roadSpeedLimit = mapData.graph[route.path[n2.pathidx]][route.path[n2.pathidx-1]].speedLimit
      else
        roadSpeedLimit = n2.roadSpeedLimit
      end

      if plan.stopSeg >= i + 1 then
        plan.stopSeg = plan.stopSeg + 1
      end

      local manSpeed
      if n1.manSpeed and n2.manSpeed then
        manSpeed = (n1.manSpeed + n2.manSpeed) * 0.5
      end

      tableInsert(plan, i+1, {
        posOrig = posOrig,
        pos = pos,
        vec = vec,
        dirVec = dirVec,
        turnDir = vec3(0, 0, 0),
        biNormal = biNormal,
        normal = normal,
        radiusOrig = radiusOrig,
        pathidx = n2.pathidx,
        roadSpeedLimit = roadSpeedLimit,
        halfWidth = roadHalfWidth,
        widthMarginOffset = (n1.widthMarginOffset + n2.widthMarginOffset) * 0.5,
        laneLimLeft = laneLimLeft,
        laneLimRight = laneLimRight,
        rangeLeft = rangeLeft,
        rangeRight = rangeRight,
        rangeLaneCount = rangeLaneCount,
        rangeBestLane = rangeBestLane, -- 0 Indexed
        length = n1.length,
        curvature = (n1.curvature + n2.curvature) * 0.5,
        curvatureZ = 0,
        lateralXnorm = lateralXnorm,
        legalSpeed = nil,
        manSpeed = manSpeed,
        speed = nil,
        trafficSqVel = math.huge,
        dispDir = 0
      })

      if n1.lanesOpen and n2.lanesOpen then
        openLaneToLaneRange(plan[i+1])
      end

      plan.planCount = plan.planCount + 1
      break
    end
    distOnPlan = distOnPlan + sqrt(segLenSq)
  end
  --profilerPopEvent("ai_trajectory_splitting")
  distOnPlan = nil

  if plan.targetSeg == nil then
    calculateTarget(plan)
  end

  --profilerPushEvent("ai_calculate_smoothing")
  -- calculate spring forces
  local nforce = vec3()
  if opt.trajMethod ~= 'springDampers' then
    for i = 0, plan.planCount do
      if forces[i] then
        forces[i]:set(0, 0, 0)
      else
        forces[i] = vec3()
      end
    end

    for i = 1, plan.planCount-1 do
      local n1 = plan[i]
      local v1 = n1.dirVec
      local v2 = plan[i+1].dirVec

      n1.turnDir:setSub2(v1, v2); n1.turnDir:normalize()
      nforce:setScaled2(n1.turnDir, (1-twt.state) * max(1 - v1:dot(v2), 0) * parameters.turnForceCoef)

      forces[i+1]:setSub(nforce)
      forces[i-1]:setSub(nforce)
      nforce:setScaled(2)
      forces[i]:setAdd(nforce)
    end
  else
    for i = 0, plan.planCount do
      if forces[i] then
        forces[i]:set(0, 0, 0)
      else
        forces[i] = vec3()
        velocities[i] = vec3()
      end
    end

    local dforce = vec3()
    local stiff = 400
    local damper = 2
    for i = 1, plan.planCount-1 do
      local n1 = plan[i]
      local v1 = n1.dirVec
      local v2 = plan[i+1].dirVec

      n1.turnDir:setSub2(v1, v2); n1.turnDir:normalize()
      nforce:setScaled2(n1.turnDir, (1-twt.state) * max(1 - v1:dot(v2), 0) * parameters.turnForceCoef)

      nforce:setScaled2(n1.turnDir, (1-twt.state) * max(1 - v1:dot(v2), 0) * parameters.turnForceCoef * stiff)
      dforce:setScaled2((velocities[i+1] - velocities[i]) - (velocities[i] - velocities[i-1]), parameters.turnForceCoef * damper * 0.25)
      dforce:setScaled2(n1.turnDir, n1.turnDir:dot(dforce))
      nforce:setAdd(dforce)

      forces[i+1]:setSub(nforce)
      forces[i-1]:setSub(nforce)
      nforce:setScaled(2)
      forces[i]:setAdd(nforce)
    end

    for i = 1, plan.planCount-1 do
      forces[i] = forces[i] - velocities[i] * parameters.turnForceCoef * damper
      velocities[i] = velocities[i] + forces[i] * dt
      forces[i] = velocities[i] * dt
    end
  end
  --profilerPopEvent("ai_calculate_smoothing")

  -- other vehicle awareness --
  -- computing path indexes (start/final) for trafficFilter
  -- and computing filter radius
  --profilerPushEvent("ai_awareness")
  local indexes = {start = plan[1].pathidx , final = plan[plan.planCount].pathidx}
  if traffic.filtered then
    traffic.Rfs = traffic.Rfs_fun(ai.speed)
    traffic.Rfl = traffic.Rfl_fun(ai.speed)
    traffic.distAhead = traffic.Rfs
    local dist = plan.planLen
    local final = indexes.final
    while (dist < traffic.distAhead or final < indexes.start + 1) and route.path[final + 1] do
      dist = dist + mapData.positions[route.path[final]]:distance(mapData.positions[route.path[final+1]])
      final = final + 1
    end
    --obj.debugDrawProxy:drawSphere(2, mapData.positions[route.path[final]], color(0,255,0,50))
    indexes.final = final
  end

  table.clear(traffic.trafficTable)
  ai.ghostR, ai.ghostL = nil, nil

  for plID, v in pairs(mapmgr.getObjects()) do
    if plID ~= objectId and (M.mode ~= 'chase' or plID ~= player.id or internalState.chaseData.playerState == 'stopped') then
      v.targetType = (player and plID == player.id) and M.mode
      if opt.avoidCars == 'on' or v.targetType == 'follow' then
        v.length = obj:getObjectInitialLength(plID) + 0.3
        v.width = obj:getObjectInitialWidth(plID)
        local posFront = obj:getObjectFrontPosition(plID)
        local dirVec = v.dirVec
        v.posFront = dirVec * 0.3 + posFront
        v.posRear = dirVec * (-v.length) + posFront
        v.posMiddle = (v.posFront + v.posRear) * 0.5
        --obj.debugDrawProxy:drawSphere(traffic.Rfs, ai.pos, color(0,0,0,50))
        --obj.debugDrawProxy:drawSphere(traffic.Rfl, ai.pos, color(255,0,0,50))

        if traffic.filtered then
          local dist = ai.pos:squaredDistance(v.posMiddle)
          if dist <= traffic.Rfs * traffic.Rfs then
            -- process with trafficFilter vehicles inside smaller radius
            if trafficFilter(indexes, route, v, traffic.vdraw) then
              table.insert(traffic.trafficTable, v)
            end
            -- be sure to not have this vehicle inside Que
            traffic.trafficFilterQue.dict[plID] = nil
            -- set FromQue to nil (means that this vehicle was not taken from Que)
            traffic.trafficFilterFromQue[plID] = nil
          elseif dist <= traffic.Rfl * traffic.Rfl then
            -- process with trafficFilter vehicles inside larger radius
            if traffic.trafficFilterFromQue[plID] then
              -- if vehicle (at the previous frame) was taken from Que, then process it again with trafficFilter
              if trafficFilter(indexes, route, v, traffic.vdraw) then
                table.insert(traffic.trafficTable, v)
              end
              -- be sure to not have this vehicle inside Que
              traffic.trafficFilterQue.dict[plID] = nil
            else
              -- if it is not has been processed from que, then add it to que if it is not already inside
              if not traffic.trafficFilterQue.dict[plID] then
                table.insert(traffic.trafficFilterQue.array, plID)
                traffic.trafficFilterQue.dict[plID] = true
                traffic.trafficFilterFromQue[plID] = nil
              end
            end
          else
            -- process vehicles outside of both radii
            traffic.trafficFilterQue.dict[plID] = nil
            traffic.trafficFilterFromQue[plID] = nil
          end
        else -- no filtered case (take all vehicles)
          table.insert(traffic.trafficTable, v)
        end
      end
    end
  end

  if traffic.filtered then
    local tFQarray, tFQdict = traffic.trafficFilterQue.array, traffic.trafficFilterQue.dict
    -- cleanup trafficFilterQue
    local j = 1
    for i = 1, #tFQarray do
      local vid = tFQarray[i]
      if tFQdict[vid] and mapmgr.objects[vid] and mapmgr.objects[vid].posFront then --
        if i ~= j then
          tFQarray[j] = tFQarray[i]
          tFQarray[i] = nil
        end
        j = j + 1
      else
        tFQarray[i], tFQdict[vid] = nil, nil
      end
    end

    -- pop que and check vehicle
    if tFQarray[1] and (traffic.frameQue*dt >= traffic.rateQue) then
      local vid = table.remove(tFQarray, 1)
      tFQdict[vid] = nil
      local v = mapmgr.objects[vid]
      -- process the first vehicle in Que
      if trafficFilter(indexes, route, v, traffic.vdraw) then
        -- set FromQue to true (means that this vehicle was taken from Que)
        traffic.trafficFilterFromQue[vid] = true
        table.insert(traffic.trafficTable, v)
      end
      traffic.frameQue = 0
    end
  end


  local trafficTableLen = #traffic.trafficTable
  plan.trafficMinProjSpeed = math.huge


  local newOvertake = false
  local openPlanLanesIdx = 0
  if trafficTableLen > 0 then
    local fl, rl, fr, rr
    local lenVec = ai.dirVec * ai.length
    local midPos = ai.pos - lenVec * 0.5
    --local planPos = linePointFromXnorm(plan[1].pos, plan[2].pos, plan.aiXnormOnSeg or 0)
    --midPos = linePointFromXnorm(planPos, planPos - lenVec, midPos:xnormOnLine(planPos, planPos - lenVec)) -- offset as next plan node
    local dispLeft, dispRight = 0, 0

    if opt.racing then
      for _, v in ipairs(traffic.trafficTable) do -- side avoidance loop
        local backAwereness = 0 --0.25 -- must be between 0 and 1
        local xnormF = v.posFront:xnormOnLine(midPos + lenVec, midPos - backAwereness * lenVec)
        local xnormR = v.posRear:xnormOnLine(midPos + lenVec, midPos - backAwereness * lenVec)
        local xnormL = xnormF > 0 and xnormF or xnormR
        if ai.speed > 1 and v.vel:dot(ai.dirVec) > 0 and xnormL > 0 and xnormL < 1 and abs(v.posFront.z - ai.pos.z) < 4 then
          -- distance from ai.pos to v.posFront or v.posRear
          local distF = (v.posFront - ai.pos):dot(ai.rightVec)
          local distR = (v.posRear - ai.pos):dot(ai.rightVec)
          -- side of v w.r.t. ai (ai -> v = 1, v <- ai = -1)
          local side = sign(distR)

          local dist = min(abs(distF), abs(distR))
          -- Relative Velocity of ai w.r.t. v vehicle
          local vRel = ai.vel - v.vel
          -- relative lateral speed of v w.r.t. ai (rsLat > 0 means v is moving toward us)
          local rsLat = vRel:dot(ai.rightVec) * side
          -- time to lateral collision (> 0 means collision is imminent, < 0 means collision does not happen)
          local TTC = dist * sign2(rsLat) / (abs(rsLat) + 1e-30)
          -- relative longitudinal speed of v w.r.t. ai (rsLong > 0 means ai is moving faster than v)
          local rsLong = vRel:dot(ai.dirVec)

          local TTO
          if rsLong > 0 then -- time to overtake v
            TTO = (2 * ai.length * lerp(1, lerp(0.5, 0, backAwereness), xnormL) + (xnormF < 0 and v.length or 0)) / (rsLong + 1e-30)
          else -- time to be overtaken by v
            TTO = (2 * ai.length * lerp(0.5, 1, backAwereness)*xnormL + (xnormF > 0 and v.length or 0))/ (-rsLong + 1e-30)
          end

          -- if TTC is less than TTO or if is greater but vehicles are close to each other: ACTIVATE SIDE AVOIDANCE
          if v.dirVec:dot(ai.dirVec) > 0.3 then
            if TTC > 0 and TTC < min(3, TTO) then
              if side < 0 then -- v-vehicle is on our left side
                dispLeft = max(dispLeft, square(clamp(0.1 / TTC, 0, 1)))
              elseif side > 0 then -- v-vehicle is on our right side  --(and (xnormF < 0.5 or v.vel:dot(ai.dirVec) > ai.speed))
                dispRight = max(dispRight, square(clamp(0.1 / TTC, 0, 1)))
              end
              --obj.debugDrawProxy:drawSphere(0.2, ai.pos + 0.5 * ai.dirVec * ai.length, color(255, 128, 0, 160))
              --obj.debugDrawProxy:drawSphere(0.2, midPos, color(255, 128, 0, 160))
            elseif dist < 0.5 * (ai.width + v.width + 0.2) and TTC > -0.1 then
              if side < 0 then -- v-vehicle is on our left side
                dispLeft = max(dispLeft, 0.1)
              elseif side > 0 then -- v-vehicle is on our right side  --(and (xnormF < 0.5 or v.vel:dot(ai.dirVec) > ai.speed))
                dispRight = max(dispRight, 0.1)
              end
              --obj.debugDrawProxy:drawSphere(0.2, ai.pos + 0.5 * ai.dirVec * ai.length, color(0, 0, 0, 160))
              --obj.debugDrawProxy:drawSphere(0.2, midPos, color(0, 0, 0, 160))
            end
          end
        end
      end
    else
      for _, v in ipairs(traffic.trafficTable) do -- side avoidance loop
        local xnorm = v.posFront:xnormOnLine(midPos + lenVec, midPos - lenVec)
        if ai.speed > 1 and v.vel:dot(ai.dirVec) > 0 and xnorm > 0 and xnorm < 1 and abs(v.posFront.z - ai.pos.z) < 4 then
          fl = fl or midPos - ai.rightVec * ai.width * 0.5 + lenVec
          rl = rl or fl - lenVec * 2
          fr = fr or midPos + ai.rightVec * ai.width * 0.5 + lenVec
          rr = rr or fr - lenVec * 2

          local posF = v.posFront
          local rightVec = v.dirVec:cross(v.dirVecUp)
          local posL = posF - rightVec * (v.width * 0.5 + 0.1)
          local posR = posF + rightVec * (v.width * 0.5 + 0.1)

          local xnorm1, xnorm2 = closestLinePoints(posF, posR, rl, fl)
          local xnorm3, xnorm4 = closestLinePoints(posF, posL, rr, fr)

          if xnorm1 > 0 and xnorm1 < 1 and xnorm2 > 0 and xnorm2 < 1 then -- v-vehicle is on our left side
            dispLeft = max(dispLeft, linePointFromXnorm(posF, posR, xnorm1):squaredDistance(posR))
          elseif xnorm3 > 0 and xnorm3 < 1 and xnorm4 > 0 and xnorm4 < 1 then -- v-vehicle is on our right side
            dispRight = max(dispRight, linePointFromXnorm(posF, posL, xnorm3):squaredDistance(posL))
          end
        end
      end
    end

    --if fl then
      --local cornerColor = color(255, 128, 0, 160)
      --obj.debugDrawProxy:drawSphere(0.2, fl, cornerColor)
      --obj.debugDrawProxy:drawSphere(0.2, rl, cornerColor)
      --obj.debugDrawProxy:drawSphere(0.2, fr, cornerColor)
      --obj.debugDrawProxy:drawSphere(0.2, rr, cornerColor)
      --local sideColor = color(clamp(sqrt(dispLeft) * 255, 0, 255), 0, clamp(sqrt(dispRight) * 255, 0, 255), 160)
      --obj.debugDrawProxy:drawSphere(0.4, midPos + vec3(0,0,2), sideColor)
    --end

    plan.sideDisp = nil
    if dispLeft > 0 or dispRight > 0 then
      local sideDisp = sqrt(dispLeft) - sqrt(dispRight) -- (sideDisp > 0) means v-vehicle is on our left side and ai should move right
      sideDisp = min(dt * parameters.awarenessForceCoef * 10, abs(sideDisp)) * sign2(sideDisp) -- limited displacement per frame
      plan.sideDisp = true
      -- maybe needs some smoother to prevent left / right "bouncing"
      local curDist = 0
      local lastPlanIdx = 2
      local targetDist = square(ai.speed) / (2 * g * aggression) + max(opt.racing and 100 or 30, ai.speed * 3) -- longer adjustment at higher speeds

      local tmpVec = vec3()
      for i = 2, plan.planCount - 1 do
        openLaneToLaneRange(plan[i])
        plan[i].lateralXnorm = clamp(plan[i].lateralXnorm + sideDisp * (targetDist - curDist) / targetDist, plan[i].laneLimLeft, plan[i].laneLimRight)
        tmpVec:setScaled2(plan[i].normal, plan[i].lateralXnorm)
        plan[i].pos:setAdd2(plan[i].posOrig, tmpVec)
        curDist = curDist + plan[i - 1].length
        lastPlanIdx = i

        plan[i].vec:setSub2(plan[i-1].pos, plan[i].pos); plan[i].vec.z = 0
        plan[i].dirVec:set(plan[i].vec)
        plan[i].dirVec:normalize()

        if curDist > targetDist then break end
      end

      updatePlanLen(plan, 2, lastPlanIdx + 1)
    end

    local trafficMinSpeedSq = math.huge
    local distanceT = 0
    local minTrafficDir = 1
    local nDir, forceVec = vec3(), vec3()
    nDir:setSub2(plan[2].pos, plan[1].pos); nDir:setScaled(1 / (plan[1].length + 1e-30))
    local aiPathVel = ai.vel:dot(nDir)
    local aiPathVelInv = 1 / abs(aiPathVel + 1e-30)
    local inMultipleLanes = plan[2].laneLimRight - plan[2].laneLimLeft > 3.45 * 1.5 -- one and a half lanes
    for i = 2, plan.planCount-1 do
      local arrivalT = distanceT * aiPathVelInv
      local n1, n2 = plan[i], plan[i+1]
      local n1pos, n2pos = n1.pos, n2.pos
      nDir:setSub2(n2pos, n1pos); nDir:setScaled(1 / (n1.length + 1e-30))
      n1.trafficSqVel = math.huge

      for j = trafficTableLen, 1, -1 do
        local v = traffic.trafficTable[j]
        local plPosFront, plPosRear, plWidth = v.posFront, v.posRear, v.width
        local ai2PlVec = plPosFront - ai.pos
        local ai2PlDir = ai2PlVec:dot(ai.dirVec)

        if ai2PlDir > 0 then
          local velDisp = arrivalT * v.vel
          if v.vel:length() < ai.speed and (v.noproj or opt.racing) then
            velDisp = velDisp * min(1,square(square(square(max(0,arrivalT/4)))))
          end
          plPosFront = plPosFront + velDisp
          plPosRear = plPosRear + velDisp
        end

        local extVec = 0.5 * max(ai.width, plWidth) * nDir
        local n1ext, n2ext = n1pos - extVec, n2pos + extVec
        local rnorm, vnorm = closestLinePoints(n1ext, n2ext, plPosFront, plPosRear)

        local minSqDist = math.huge
        if rnorm > 0 and rnorm < 1 and vnorm > 0 and vnorm < 1 then
          minSqDist = 0
        else
          local rlen = n1.length + plWidth
          local xnorm = plPosFront:xnormOnLine(n1ext, n2ext) * rlen
          local v1 = vec3()
          if xnorm > 0 and xnorm < rlen then
            v1:setScaled2(nDir, xnorm); v1:setAdd(n1ext)
            minSqDist = min(minSqDist, v1:squaredDistance(plPosFront))
          end

          xnorm = plPosRear:xnormOnLine(n1ext, n2ext) * rlen
          if xnorm > 0 and xnorm < rlen then
            v1:setScaled2(nDir, xnorm); v1:setAdd(n1ext)
            minSqDist = min(minSqDist, v1:squaredDistance(plPosRear))
          end

          rlen = v.length + ai.width
          v1:setSub2(n1ext, plPosRear)
          local v1dot = v1:dot(v.dirVec)
          if v1dot > 0 and v1dot < rlen then
            minSqDist = min(minSqDist, v1:squaredDistance(v1dot * v.dirVec))
          end

          v1:setSub2(n2ext, plPosRear)
          v1dot = v1:dot(v.dirVec)
          if v1dot > 0 and v1dot < rlen then
            minSqDist = min(minSqDist, v1:squaredDistance(v1dot * v.dirVec))
          end
        end

        local limWidth = v.targetType == 'follow' and 2 * max(n1.radiusOrig, n2.radiusOrig) or plWidth

        if minSqDist < square((ai.width + limWidth) * 0.8) then
          local velProjOnSeg = max(0, v.vel:dot(nDir))

          local vehicleIsStopped = isVehicleStopped(v)

          if vehicleIsStopped then
            local distToParked = 0
            for ii = 2, i do
              distToParked = distToParked + plan[ii].length
            end
            if distToParked < 25 then
              openPlanLanesIdx = max(openPlanLanesIdx, i)
            end
          end

          if not newOvertake then
            if plan.stopSeg == math.huge and v.targetType ~= 'follow' then -- apply side forces to avoid vehicles
              local side1 = sign(n1.normal:dot(v.posMiddle) - n1.normal:dot(n1.pos))
              local side2 = sign(n2.normal:dot(v.posMiddle) - n2.normal:dot(n2.pos))

              if not v.sideDir then
                v.sideDir = side1 -- save the avoidance direction once to compare it with all of the subsequent plan nodes
              end

              if v.sideDir == side1 and inMultipleLanes then -- calculate force coef only if the avoidance side matches the initial value

                local forceCoef = trafficStates.side.side *
                                  parameters.awarenessForceCoef *
                                  max(0, ai.speed - velProjOnSeg, -sign(nDir:dot(v.dirVec)) * trafficStates.side.cTimer) /
                                  ((1 + minSqDist) * (1 + distanceT * min(0.1, 1 / (2 * max(0, aiPathVel - v.vel:dot(nDir)) + 1e-30))))

                if opt.racing then
                  forceCoef = forceCoef * 0.25
                end
                forceVec:setScaled2(n1.normal, side1 * forceCoef)
                forces[i]:setSub(forceVec)

                forceVec:setScaled2(n1.normal, side2 * forceCoef)
                forces[i+1]:setSub(forceVec)
              end
            end
          else
            if plan.stopSeg == math.huge and v.targetType ~= 'follow' and not v.overtaken then
              v.overtaken = true
              if inMultipleLanes then
                local Deltax = distanceT
                local factor1 = clamp(ai.vel:dot(nDir) - velProjOnSeg, 0, 4)
                local factor2 = max(0,-sign(nDir:dot(v.dirVec)) * trafficStates.side.cTimer)
                for ii = 2, plan.planCount-1 do
                  -- Logic for performing the overtake manouver
                  local n1i = plan[ii]
                  --local n2i = plan[ii + 1]
                  local distY = n1i.normal:dot(v.posMiddle) - n1i.normal:dot(n1i.pos)
                  --local distY = plan[1].normal:dot(v.posMiddle) - plan[1].normal:dot(ai.pos)
                  --local Deltax = -n2i.dirVec:dot(v.posMiddle - n1i.pos) --Need to be improved
                  if ii > 2 then
                    Deltax = Deltax - plan[ii-1].length
                  end
                  if not v.sideDir then
                    v.sideDir = sign(distY) -- save the avoidance direction once to compare it with all of the subsequent plan nodes
                  end
                  if v.sideDir == sign(distY) then
                    local forceCoef = sign(distY)*max(0, ((n1i.radiusOrig) - abs(distY))*math.exp(-0.001*square(Deltax)))*(1*parameters.awarenessForceCoef*dt)
                    forceCoef = forceCoef*max(factor1, factor2)*trafficStates.side.side
                    forceVec:setScaled2(n1i.normal, forceCoef)
                    forces[ii]:setSub(forceVec)
                  end
                end
              end
            end
          end

          if M.mode ~= 'flee' and M.mode ~= 'random' and (M.mode ~= 'manual' or (n1.laneLimRight - n1.laneLimLeft) <= ai.width + plWidth) then
            -- sets a minimum speed due to other vehicle velocity projection on plan segment
            -- only sets it if ai mode is valid; or if mode is "manual" but there is not enough space to pass

            if minSqDist < square((ai.width + limWidth) * 0.51)  then
              -- obj.debugDrawProxy:drawSphere(0.25, v.posFront, color(0,0,255,255))
              -- obj.debugDrawProxy:drawSphere(0.25, plPosFront, color(0,0,255,255))
              if not vehicleIsStopped then
                table.remove(traffic.trafficTable, j)
                trafficTableLen = trafficTableLen - 1
              end
              plan.trafficMinProjSpeed = min(plan.trafficMinProjSpeed, velProjOnSeg)

              n1.trafficSqVel = min(n1.trafficSqVel, velProjOnSeg * velProjOnSeg)
              trafficMinSpeedSq = min(trafficMinSpeedSq, v.vel:squaredLength())
              minTrafficDir = min(minTrafficDir, v.dirVec:dot(nDir))
            end

            if i == 2 and minSqDist < square((ai.width + limWidth) * 0.6) and ai2PlDir > 0 and v.vel:dot(ai.rightVec) * ai2PlVec:dot(ai.rightVec) < 0 then
              n1.trafficSqVel = max(0, n1.trafficSqVel - abs(1 - v.vel:dot(ai.dirVec)) * (v.vel:length()))
            end
          end
        end
      end

      distanceT = distanceT + n1.length

      if trafficTableLen < 1 then
        break
      end
    end

    -- this code was supposed to keep the vehicle stopped until the intersection was clear
    -- not working as intended, different solution needed
    --if trafficStates.intersection.timer < parameters.trafficWaitTime and plan.trafficMinProjSpeed < 3 then
      --trafficStates.intersection.timer = 0 -- reset the intersection waiting timer
    --end

    trafficStates.block.block = max(trafficMinSpeedSq, ai.speed*ai.speed) < 1 and (minTrafficDir < -0.7 or trafficStates.intersection.block)
    if not opt.racing then
      plan[1].trafficSqVel = plan[2].trafficSqVel
    end

    if openPlanLanesIdx > 0 and plan[openPlanLanesIdx].length < ai.length * 1.5 then openPlanLanesIdx = openPlanLanesIdx + 1 end

    openPlanLanesToLaneRange(plan, openPlanLanesIdx)
  end
  --profilerPopEvent("ai_awareness")

  -- remove lane change if vehicle has gone past it
  --profilerPushEvent("ai_remove_laneChange")
  while route.laneChanges[1] and plan[2].pathidx > route.laneChanges[1].pathIdx do
    electrics.stop_turn_signal()
    table.remove(route.laneChanges, 1)
  end
  --profilerPopEvent("ai_remove_laneChange")

  local skipLast = 1
  local lastNodeLatXnorm, lastNodeLimLeft, lastNodeLimRight

  --profilerPushEvent("ai_process_laneChange")
  if route.laneChanges[1] and math.floor(plan[2].rangeLaneCount + 0.5) > 1 and route.laneChanges[1].side ~= 0 then
    local exitNodeIdx = route.laneChanges[1].pathIdx
    local distToExit
    if plan[plan.planCount].pathidx > exitNodeIdx then
      distToExit = plan.planLen
      for i = plan.planCount, 2, -1 do
        if plan[i].pathidx == exitNodeIdx then
          break
        else
          distToExit = distToExit - plan[i-1].length
        end
      end
    else
      distToExit = plan.planLen + max(0, route.pathLength[route.laneChanges[1].pathIdx] - route.pathLength[plan[plan.planCount].pathidx])
    end

    if (distToExit < min(600, max(15, ai.speed * ai.speed * 0.7)) or route.laneChanges[1].commit) then --and not plan.noExit
      local side = route.laneChanges[1].side
      -- check if the exit is blocked by a vehicle
      if (side < 0 and ai.ghostL) or (side > 0 and ai.ghostR) then
        plan.noExit = true
      else
        plan.noExit = nil
      end

      -- if the exit is not blocked, do a lane change
      if not plan.noExit or route.laneChanges[1].commit then
        route.laneChanges[1].commit = true
        --print('lane change is going to happen')
        --obj.debugDrawProxy:drawSphere(2, ai.pos, color(255,0,255,255))
        if side < 0 then
          if (electrics.values.turnsignal or -1) >= 0 then electrics.toggle_left_signal() end
        else
          if (electrics.values.turnsignal or 1) <= 0 then electrics.toggle_right_signal() end
        end
        skipLast = 0
        lastNodeLatXnorm = plan[plan.planCount].lateralXnorm
        lastNodeLimLeft = plan[plan.planCount].laneLimLeft
        lastNodeLimRight = plan[plan.planCount].laneLimRight
        local planDist = 0
        local sideForceCoeff = 2.5 * side * dt / distToExit
        local planExitIdx = plan.planCount
        if plan[plan.planCount].pathidx >= exitNodeIdx then -- if last plan node is at or past the path exit node
          planExitIdx = 1
          for i = plan.planCount, 3, -1 do
            if plan[i].pathidx == exitNodeIdx then -- if this plan node is at the exit node
              if i == plan.planCount then -- if it is also the last plan node
                lastNodeLatXnorm = nil
              end
              planExitIdx = i
              break
            end
          end
        else
          lastNodeLatXnorm = nil
        end

        -- Add lane change forces to all nodes up to the exit node
        for i = 3, planExitIdx do
          planDist = planDist + plan[i-1].length
          local n = plan[i]
          local roadHalfWidth = n.halfWidth
          local laneHalfWidth = roadHalfWidth * (n.rangeRight - n.rangeLeft) / n.rangeLaneCount
          if side < 0 then
            n.laneLimLeft = (2 * n.rangeLeft - 1) * roadHalfWidth -- open left lane limit to left range limit
            n.laneLimRight = max(n.laneLimLeft + ai.width, min(n.laneLimRight, n.lateralXnorm + laneHalfWidth))
            forces[i]:setAdd(planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.lateralXnorm - n.laneLimLeft))) * n.normal)
          else
            n.laneLimRight = (2 * n.rangeRight - 1) * roadHalfWidth -- open right lane limit to right range limit
            n.laneLimLeft = min(n.laneLimRight - ai.width, max(n.laneLimLeft, n.lateralXnorm - laneHalfWidth))
            forces[i]:setAdd(planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.laneLimRight - n.lateralXnorm))) * n.normal)
          end
        end
        for i = planExitIdx + 1, plan.planCount do
          planDist = max(0, planDist - plan[i-1].length)
          if planDist == 0 then break end
          local n = plan[i]
          if side < 0 then
            forces[i]:setAdd(planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.lateralXnorm - n.laneLimLeft))) * n.normal)
          else
            forces[i]:setAdd(planDist * sideForceCoeff * square(min(1, 0.25 * abs(n.laneLimRight - n.lateralXnorm))) * n.normal)
          end
        end
        updatePlanbestRange(plan)
      else -- if the exit is blocked, avoid lane change by changing path & plan

        --------- Plan cleaning -----------
        local clearIdx = max(exitNodeIdx-1, plan[2].pathidx)
        -- clear all plan nodes from clearIdx to plan.planCount
        local final_plan_count = plan.planCount
        for i = plan.planCount, 1, -1 do
          if plan[i].pathidx > clearIdx then
            plan.planLen = plan.planLen - plan[i-1].length
            plan[i] = nil
            final_plan_count = final_plan_count - 1
          else
            break
          end
        end
        plan.planCount = final_plan_count

        ----------- Path cleaning -------------
        -- remove all path nodes after the exit node
        for i = #route.path, min(#route.path, exitNodeIdx) + 1, -1  do
          table.remove(route.path, i)
          table.remove(route.pathLength, i)
        end
        -- insert the alternate path at the exit node
        table.insert(route.path, route.laneChanges[1].alternate)
        -- clear route lane changes
        route.lastLaneChangeIdx = #route.path - 1
        table.clear(route.laneChanges)
        -- clear and update traffic path state for the new path
        if #trafficPathState > 0 then
          table.clear(trafficPathState)
          trafficPathState[1] = route.path[#route.path-1]
          trafficPathState[2] = route.path[#route.path]
        end
      end
    end
  end
  --profilerPopEvent("ai_process_laneChange")

  --profilerPushEvent("ai_smoothness_integration")
  local tmpVec = vec3()
  local roadWidthMargin = ai.width * 0.5
  local laneWidthMargin = ai.width * 0.4
  local forceMagLim = parameters.springForceIntegratorDispLim
  for i = 2, plan.planCount-skipLast do
    local n = plan[i]
    local roadHalfWidth = n.halfWidth

    -- Apply a force towards the center of the lane when driving in lane
    local forceToLaneCenter = 0
    if opt.driveInLaneFlag and not n.lanesOpen then
      local rangeLeft = (2 * n.rangeLeft - 1) * roadHalfWidth
      local rangeRight = (2 * n.rangeRight - 1) * roadHalfWidth
      local b = 0.5 * (n.laneLimRight - n.laneLimLeft) + 1e-30
      local dispToLeftRange = min(1, max(0, b - (n.lateralXnorm - rangeLeft)) / b)
      local dispToRightRange = min(1, max(0, b - (rangeRight - n.lateralXnorm)) / b)
      forceToLaneCenter = 0.15 * (dispToLeftRange - dispToRightRange)
    end

    -- Calculate node displacement: avoids switching displacement direction (sign) in concecutive frames
    local displacement = forceToLaneCenter + max(min(n.normal:dot(forces[i]), forceMagLim), -forceMagLim)
    displacement = displacement * max(min((displacement * n.dispDir) * math.huge, 1), 0) -- second term returns 0 if (displacement * n.dispDir) is negative, 1 otherwise.
    n.dispDir = sign(displacement)

    local roadLimRight = max(0, roadHalfWidth - roadWidthMargin) -- should be non-negative (zero or positive)

    local newLateralXnorm = clamp(n.lateralXnorm + displacement,
      max(n.laneLimLeft + laneWidthMargin, -roadLimRight),
      min(n.laneLimRight - laneWidthMargin, roadLimRight))

    tmpVec:setScaled2(n.normal, newLateralXnorm - n.lateralXnorm)
    n.pos:setAdd(tmpVec) -- remember that posOrig and pos are not alligned along the normal
    n.vec:setSub2(plan[i-1].pos, n.pos); n.vec.z = 0
    n.dirVec:set(n.vec); n.dirVec:normalize()

    n.lateralXnorm = newLateralXnorm
  end
  --profilerPopEvent("ai_smoothness_integration")

  if lastNodeLatXnorm then
    local roadHalfWidth = plan[plan.planCount].halfWidth
    local rangeLeft, rangeRight = (2 * plan[plan.planCount].rangeLeft - 1) * roadHalfWidth, (2 * plan[plan.planCount].rangeRight - 1) * roadHalfWidth
    local latXnorm = clamp(plan[plan.planCount].lateralXnorm, rangeLeft, rangeRight)
    local disp = latXnorm - lastNodeLatXnorm
    plan[plan.planCount].laneLimLeft = max(rangeLeft, min(latXnorm, lastNodeLimLeft + disp))
    plan[plan.planCount].laneLimRight = min(rangeRight, max(latXnorm, lastNodeLimRight + disp))
  end

  updatePlanLen(plan, 2, plan.planCount)

  -- smoothly distribute error from planline onto the front segments
  --profilerPushEvent("ai_error_smoother")
  if parameters.planErrorSmoothing and plan.targetPos and plan.targetSeg and plan.planCount > plan.targetSeg and twt.state == 0 then
    local dTotal = 0
    local sumLen = table.new(plan.targetSeg-1, 0)
    sumLen[1] = 0
    for i = 2, plan.targetSeg - 1  do
      sumLen[i] = dTotal
      dTotal = dTotal + plan[i].length
    end
    dTotal = max(1, dTotal + plan.targetPos:distance(plan[plan.targetSeg].pos))

    local p1, p2 = plan[1].pos, plan[2].pos
    local dispVec = ai.pos - linePointFromXnorm(p1, p2, ai.pos:xnormOnLine(p1, p2)); dispVec:setScaled(0.5 * dt)

    tmpVec:setSub2(p2, p1); tmpVec:setCross(tmpVec, ai.upVec); tmpVec:normalize()
    plan.aiDeviation = dispVec:dot(tmpVec)

    local dispVecRatio = dispVec / dTotal
    for i = plan.targetSeg - 1, 1, -1 do
      local n = plan[i]

      dispVec:setScaled2(dispVecRatio, dTotal - sumLen[i])
      dispVec:setSub(dispVec:dot(n.biNormal) * n.biNormal)
      n.pos:setAdd(dispVec)

      local halfWidth = n.halfWidth
      tmpVec:setAdd2(n.posOrig, n.normal)
      n.lateralXnorm = clamp(n.pos:xnormOnLine(n.posOrig, tmpVec), -halfWidth, halfWidth)

      plan[i+1].vec:setSub2(plan[i].pos, plan[i+1].pos); plan[i+1].vec.z = 0
      plan[i+1].dirVec:setScaled2(plan[i+1].vec, 1 / plan[i+1].vec:lengthGuarded())
    end

    updatePlanLen(plan, 1, plan.targetSeg-1)
  end
  --profilerPopEvent("ai_error_smoother")

  -- TODO: This error smoother looks to behave better for race driving. It could replace the above.
  -- uniformPlanErrorDistribution(plan)

  --profilerPushEvent("ai_calculate_target")
  calculateTarget(plan)
  --profilerPopEvent("ai_calculate_target")

  -- calculate node horizontal curvature
  --profilerPushEvent("ai_calculate_curvature")
  local len, n3vec = 0, vec3()
  plan[1].curvature = plan[1].curvature or inCurvature(plan[1].vec, plan[2].vec)
  for i = 2, plan.planCount - 1 do
    local n1, n2 = plan[i], plan[i+1]

    n3vec:setSub2(n1.pos, plan[min(plan.planCount, i+2)].pos); n3vec.z = 0

    local c1 = inCurvature(n1.vec, n2.vec)
    local c2 = inCurvature(n1.vec, n3vec)

    local curvature
    if c1 <= c2 then
      curvature = sign2(n1.turnDir:dot(n1.normal)) * c1
    else
      curvature = sign2((n1.vec):dot(n1.normal) - n3vec:dot(n1.normal)) * c2
    end

    -- calculate curvature temporal smoothing parameter as a function of the trajectory length distance
    local curvatureRateDt = min(5 + 0.005 * len * len, 100) * dt
    n1.curvature = n1.curvature + (curvature - n1.curvature) * curvatureRateDt / (1 + curvatureRateDt)

    len = len + n1.length
  end
  --profilerPopEvent("ai_calculate_curvature")

  -- calculate node vertical curvature
  if not opt.racing then
    len = 0
    local v1z, v2z, v3z = vec3(), vec3(), vec3()
    for i = 2, plan.planCount - 1 do
      local n1, n2 = plan[i], plan[i+1]

      v1z:set(plan[i-1].length, 0, n1.posOrig.z - plan[i-1].posOrig.z)
      v2z:set(n1.length, 0, n2.posOrig.z - n1.posOrig.z)
      v3z:set(n1.length + (n2.length or 0), 0, plan[min(plan.planCount, i + 2)].posOrig.z - n1.posOrig.z)

      local curvatureZ = min(inCurvature(v1z, v2z), inCurvature(v1z, v3z))
      --dump(i,'curvature', curvature, 'Zcurv', curvatureZ)

      -- calculate curvature temporal smoothing parameter (fast reacting, time dependent)
      local curvatureRateDt = min(25 + 0.000045 * len * len * len * len, 1000) * dt
      n1.curvatureZ = curvatureZ + (curvatureRateDt / (1 + curvatureRateDt)) * (n1.curvatureZ - curvatureZ)

      len = len + n1.length
    end
  end

  -- Speed Planning --
  local totalAccel = min(aggression, ai.staticFrictionCoef) * g

  local lastNode = plan[plan.planCount]
  if route.path[lastNode.pathidx+1] or (loopPath and noOfLaps and noOfLaps > 1) then
    if plan.stopSeg <= plan.planCount then
      lastNode.speed = 0
    else
      lastNode.speed = lastNode.manSpeed or sqrt(2 * 550 * totalAccel) -- shouldn't this be calculated based on the path length remaining?
    end
  else
    lastNode.speed = lastNode.manSpeed or 0
  end
  lastNode.roadSpeedLimit = plan[plan.planCount-1].roadSpeedLimit
  lastNode.legalSpeed = min(lastNode.roadSpeedLimit or math.huge, lastNode.speed)

  -- Use Backward or Forward + Backward algorithm
  --profilerPushEvent('ai_speedProfile')
  if speedProfileMode then
    local gT = vec3()
    for i = 1, plan.planCount-1 do -- curvature is not defined on the last plan node
      local n1, n2 = plan[i], plan[i+1]
      -- consider inclination
      gT:setSub2(n2.pos, n1.pos); gT:setScaled(gravityDir:dot(gT) / max(square(n1.length), 1e-30)) -- gravity vec parallel to road segment: positive when downhill
      local gN = gravityDir:distance(gT) -- gravity component normal to road segment
      n1.acc_max = totalAccel * gN
      n1.speed = min(n1.acc_max / max(abs(n1.curvature), 1e-30), gN * g / max(n1.curvatureZ, 1e-30)) -- available centripetal acceleration * radius
    end
    plan[plan.planCount].acc_max = plan[plan.planCount-1].acc_max

    if speedProfileMode == 'ForwBack' then
      solver_f_acc_profile(plan)
    end

    solver_b_acc_profile(plan)
  else -- Use standard algotihm with curvature
    local gT = vec3()
    for i = plan.planCount-1, 1, -1 do
      local n1, n2 = plan[i], plan[i+1]

      -- consider inclination
      gT:setSub2(n2.pos, n1.pos); gT:setScaled(gravityDir:dot(gT) / max(square(n1.length), 1e-30)) -- gravity vec parallel to road segment: positive when downhill
      local gN = gravityDir:distance(gT) -- gravity component normal to road segment

      local curvature = max(abs(n1.curvature), 1e-5)
      local turnSpeedSq = totalAccel * gN / curvature -- available centripetal acceleration * radius

      local n1SpeedSq
      if plan.stopSeg <= i then
        n1SpeedSq = 0
      else -- speed limit imposed by other traffic vehicles and speed limit imposed by trajectory geometry (curvature and path length)
        -- https://physics.stackexchange.com/questions/312569/non-uniform-circular-motion-velocity-optimization
        n1SpeedSq = min(n1.trafficSqVel, turnSpeedSq * sin(min(asin(min(1, square(n2.speed) / turnSpeedSq)) + 2 * curvature * n1.length, pi * 0.5)))
      end

      n1.speed = n1.manSpeed or
                  (M.speedMode == 'limit' and M.routeSpeed and min(M.routeSpeed, sqrt(n1SpeedSq))) or
                  (M.speedMode == 'set' and M.routeSpeed) or
                  sqrt(n1SpeedSq)

      -- Speed envelope considering road speed limits
      if M.speedMode == 'legal' then
        n2.legalSpeed = n2.legalSpeed or n2.speed

        if plan.stopSeg <= i then
          n1.legalSpeed = 0
        else -- speed limit imposed by other traffic vehicles and speed limit imposed by trajectory geometry (curvature and path length)
          local n1LegalSpeedSq = min(n1.trafficSqVel, turnSpeedSq * sin(min(asin(min(1, square(n2.legalSpeed) / turnSpeedSq)) + 2 * curvature * n1.length, pi * 0.5)))
          if n1.roadSpeedLimit then
            n1.legalSpeed = min(sqrt(n1LegalSpeedSq), n1.roadSpeedLimit * (1 + aggression * 2 - 0.6))
          else
            n1.legalSpeed = sqrt(n1LegalSpeedSq)
          end
        end
      end

      n1.trafficSqVel = math.huge
    end
  end
  --profilerPopEvent('ai_speedProfile')

  plan.targetSpeed = plan[1].speed + max(0, plan.aiXnormOnSeg) * (plan[2].speed - plan[1].speed)
  plan.targetSpeed = targetSpeedSmoother:get(plan.targetSpeed, dt)
  if M.speedMode == 'legal' then
    plan.targetSpeedLegal = plan[1].legalSpeed + max(0, plan.aiXnormOnSeg) * (plan[2].legalSpeed - plan[1].legalSpeed)
  else
    plan.targetSpeedLegal = math.huge
  end

  -- TODO: WIP
  --calculateTrafficTargetSpeed(plan, traffic.trafficTable, trafficTableLen)
  --plan.targetSpeed = min(plan.targetSpeed, plan.trafficTargetSpeed)

  return route
end

local function resetMapAndRoute()
  mapData = nil
  signalsData = nil
  currentRoute = nil
  loopPath = nil
  noOfLaps = nil
  internalState.road = 'onroad'
  internalState.changePlanTimer = 0
  resetAggression()
  resetInternalStates()
  resetParameters()
end

local function getMapEdges(cutOffDrivability, node)
  -- creates a table (edgeDict) with map edges with drivability > cutOffDrivability
  if mapData ~= nil then
    local allSCC = mapData:scc(node) -- An array of dicts containing all strongly connected components reachable from 'node'.
    local maxSccLen = 0
    local sccIdx
    for i, scc in ipairs(allSCC) do
      -- finds the scc with the most nodes
      local sccLen = scc[0] -- position at which the number of nodes in currentSCC is stored
      if sccLen > maxSccLen then
        sccIdx = i
        maxSccLen = sccLen
      end
      scc[0] = nil
    end
    local currentSCC = allSCC[sccIdx]
    local keySet = {}
    local keySetLen = 0

    edgeDict = {}
    for nid, n in pairs(mapData.graph) do
      if currentSCC[nid] or not opt.driveInLaneFlag then
        for lid, data in pairs(n) do
          if (currentSCC[lid] or not opt.driveInLaneFlag) and (data.drivability > cutOffDrivability) then
            local inNode = data.inNode or nid
            local outNode = inNode == nid and lid or nid
            keySetLen = keySetLen + 1
            keySet[keySetLen] = {inNode, outNode}
            edgeDict[inNode..'\0'..outNode] = 1
            if not data.inNode or not opt.driveInLaneFlag then
              edgeDict[outNode..'\0'..inNode] = 1
            end
          end
        end
      end
    end

    if keySetLen == 0 then return end
    local edge = keySet[math.random(keySetLen)]

    return edge[1], edge[2]
  end
end

local function newManualPath()
  local newRoute, n1, n2, dist
  local offRoad = false

  if manualPath then
    if currentRoute and currentRoute.path then
      pathExtend(currentRoute.path, manualPath)
    else
      newRoute = createNewRoute(manualPath)
      currentRoute = newRoute
    end
    manualPath = nil
  elseif wpList then
    if currentRoute and currentRoute.path then
      newRoute = {
        path = currentRoute.path,
        plan = currentRoute.plan,
        laneChanges = currentRoute.laneChanges,
        lastLaneChangeIdx = currentRoute.lastLaneChangeIdx,
        pathLength = currentRoute.pathLength
      }
    else
      n1, n2, dist = mapmgr.findClosestRoad(ai.pos)

      if n1 == nil or n2 == nil then
        guihooks.message("Could not find a road network, or closest road is too far", 5, "AI debug")
        log('D', "AI", "Could not find a road network, or closest road is too far")
        return
      end

      ai.currentSegment[1] = n1
      ai.currentSegment[2] = n2

      if dist > 2 * max(mapData.radius[n1], mapData.radius[n2]) then
        offRoad = true
        local vec1 = mapData.positions[n1] - ai.pos
        local vec2 = mapData.positions[n2] - ai.pos

        if ai.dirVec:dot(vec1) > 0 and ai.dirVec:dot(vec2) > 0 then
          if vec1:squaredLength() > vec2:squaredLength() then
            n1, n2 = n2, n1
          end
        elseif ai.dirVec:dot(mapData.positions[n2] - mapData.positions[n1]) > 0 then
          n1, n2 = n2, n1
        end
      elseif ai.dirVec:dot(mapData.positions[n2] - mapData.positions[n1]) > 0 then
        n1, n2 = n2, n1
      end

      newRoute = createNewRoute({n1})
    end

    for i = 0, #wpList-1 do
      local wp1 = wpList[i] or newRoute.path[#newRoute.path]
      local wp2 = wpList[i+1]
      local route = mapData:getPath(wp1, wp2, opt.driveInLaneFlag and 1e4 or 1)
      local routeLen = #route
      if routeLen == 0 or (routeLen == 1 and wp2 ~= wp1) then
        guihooks.message("Path between waypoints '".. wp1 .."' - '".. wp2 .."' Not Found", 7, "AI debug")
        log('D', "AI", "Path between waypoints '".. wp1 .."' - '".. wp2 .."' Not Found")
        return
      end

      for j = 2, routeLen do
        tableInsert(newRoute.path, route[j])
      end
    end

    wpList = nil

    if not offRoad and newRoute.path[3] and newRoute.path[2] == n2 then
      tableRemove(newRoute.path, 1)
    end

    currentRoute = newRoute
  end
end

local function setScriptedPath(arg)
  mapmgr.setCustomMap(arg.mapData)
  mapData = mapmgr.mapData

  setParameters({driveStyle = arg.driveStyle or 'default',
                staticFrictionCoefMult = max(0.95, arg.staticFrictionCoefMult or 0.95),
                lookAheadKv = max(0.1, arg.lookAheadKv or parameters.lookAheadKv),
                planErrorSmoothing = false,
                applyWidthMarginOffset = false,
                springForceIntegratorDispLim = 0,
                turnForceCoef = 2})

  opt.avoidCars = arg.avoidCars or 'off'

  setSpeed(arg.routeSpeed)
  setSpeedMode(arg.routeSpeedMode)
  setAggressionExternal(arg.aggression)

  if arg.speedProfile and next(arg.speedProfile) then
    speedProfile = arg.speedProfile
  end

  currentRoute = createNewRoute(arg.path) -- {path = arg.path, plan = {}}

  stateChanged()
end

local function validateUserInput(list)
  validateInput = nop
  list = list or wpList
  if not list then return end
  local isValid = list[1] and true or false
  for i = 1, #list do -- #wpList
    local nodeAlias = mapmgr.nodeAliases[list[i]]
    if nodeAlias then
      if mapData.graph[nodeAlias] then
        list[i] = nodeAlias
      else
        if isValid then
          guihooks.message("One or more of the waypoints were not found on the map. Check the game console for more info.", 6, "AI debug")
          log('D', "AI", "The waypoints with the following names could not be found on the Map")
          isValid = false
        end
        -- print(list[i])
      end
    end
  end

  return isValid
end

local function fleePlan()
  if opt.aggressionMode == 'rubberBand' then
    setAggressionInternal(max(0.3, 0.95 - 0.0015 * player.pos:distance(ai.pos)))
  end

  -- extend the plan if possible and desirable
  if currentRoute and not currentRoute.plan.reRoute then
    local plan = currentRoute.plan
    if (ai.pos - player.pos):dot(ai.dirVec) >= 0 and not targetWPName and internalState.road ~= 'offroad' and plan.trafficMinProjSpeed > 3 then
      local path = currentRoute.path
      local pathCount = #path
      if pathCount >= 3 and plan[2].pathidx > pathCount * 0.7 then
        local cr1 = path[pathCount-1]
        local cr2 = path[pathCount]
        local dirVec = mapData.positions[cr2] - mapData.positions[cr1]
        dirVec:normalize()
        pathExtend(path, mapData:getFleePath(cr2, dirVec, player.pos, getMinPlanLen(), 0.01, 0.01))
        planAhead(currentRoute)
        return
      end
    end
  end

  if not currentRoute or internalState.changePlanTimer == 0 or currentRoute.plan.reRoute then
    local wp1, wp2 = mapmgr.findClosestRoad(ai.pos)
    if wp1 == nil or wp2 == nil then
      internalState.road = 'offroad'
      return
    else
      internalState.road = 'onroad'
    end

    ai.currentSegment[1] = wp1
    ai.currentSegment[2] = wp2

    local dirVec
    if currentRoute and currentRoute.plan.trafficMinProjSpeed < 3 then
      internalState.changePlanTimer = 5
      dirVec = -ai.dirVec
    else
      dirVec = ai.dirVec
    end

    local startnode = pickAiWp(wp1, wp2, dirVec)
    local path
    if not targetWPName then
      path = mapData:getFleePath(startnode, dirVec, player.pos, getMinPlanLen(), 0.01, 0.01)
    else -- flee to destination
      path = mapData:getPathAwayFrom(startnode, targetWPName, ai.pos, player.pos)
      if next(path) == nil then
        targetWPName = nil
      end
    end

    if not path[1] then
      internalState.road = 'offroad'
      return
    else
      internalState.road = 'onroad'
    end

    local route = planAhead(path, currentRoute)
    if route and route.plan then
      local tempPlan = route.plan
      if not currentRoute or internalState.changePlanTimer > 0 or tempPlan.targetSpeed >= min(ai.speed, currentRoute.plan.targetSpeed) and targetsCompatible(currentRoute, route) then
        currentRoute = route
        internalState.changePlanTimer = max(1, internalState.changePlanTimer)
        return
      elseif currentRoute.plan.reRoute then
        currentRoute = route
        internalState.changePlanTimer = max(1, internalState.changePlanTimer)
        return
      end
    end
  end

  planAhead(currentRoute)
end

local function chasePlan()
  local positions = mapData.positions
  local radii = mapData.radius

  internalState.chaseData.targetSpeed = nil

  local wp1, wp2, dist1 = mapmgr.findBestRoad(ai.pos, ai.dirVec)
  if wp1 == nil or wp2 == nil then
    internalState.road = 'offroad'
    return
  end

  local playerSpeed = player.vel:length()
  local playerVel = playerSpeed > 1 and player.vel or player.dirVec -- uses dirVec for very low speeds

  local plwp1, plwp2, dist2 = mapmgr.findBestRoad(player.pos, playerVel)
  if plwp1 == nil or plwp2 == nil then
    internalState.road = 'offroad'
    return
  end

  if ai.dirVec:dot(positions[wp2] - positions[wp1]) < 0 then wp1, wp2 = wp2, wp1 end
  -- wp2 is next node for ai to drive to

  ai.currentSegment[1] = wp1
  ai.currentSegment[2] = wp2

  if (playerVel / (playerSpeed + 1e-30)):dot(positions[plwp2] - positions[plwp1]) < 0 then plwp1, plwp2 = plwp2, plwp1 end
  -- plwp2 is next node that player is driving to

  if dist1 > max(radii[wp1], radii[wp2]) + ai.width and dist2 > max(radii[plwp1], radii[plwp2]) + obj:getObjectInitialWidth(player.id) then
    internalState.road = 'offroad'
    return
  end

  local playerNode = plwp2
  local aiPlDist = ai.pos:distance(player.pos) -- should this be a signed distance?
  local aiPosRear = ai.pos - ai.dirVec * ai.length
  local nearDist = max(ai.length + 8, internalState.chaseData.playerStoppedTimer) -- larger if player stopped for longer (anti softlock)
  local isAtPlayerSeg = (wp1 == playerNode or wp2 == playerNode)

  if opt.aggressionMode == 'rubberBand' then
    if M.mode == 'follow' then
      setAggressionInternal(min(0.75, 0.3 + 0.0025 * aiPlDist))
    else
      setAggressionInternal(min(0.95, 0.8 + 0.0015 * aiPlDist))
    end
  end

  -- consider calculating the aggression value but then passing it through a smoother so that transitions between chase mode and follow mode are smooth

  if playerSpeed < 1 then
    internalState.chaseData.playerStoppedTimer = internalState.chaseData.playerStoppedTimer + dt
  else
    internalState.chaseData.playerStoppedTimer = 0
  end

  if internalState.chaseData.playerStoppedTimer > 5 and aiPlDist < max(nearDist, square(ai.speed) / (2 * g * aggression)) then -- within braking distance to player
    internalState.chaseData.playerState = 'stopped'

    if ai.speed < 0.3 and aiPlDist < nearDist then
      -- do not plan new route if stopped near player
      currentRoute = nil
      internalState.road = 'onroad'
      return
    end
  else
    internalState.chaseData.playerState = nil
  end

  if internalState.chaseData.driveAhead and ai.speed >= 10 then -- unset this flag if the ai reached a minimum speed
    internalState.chaseData.driveAhead = false
  end

  if M.mode == 'follow' and ai.speed < 0.3 and isAtPlayerSeg and aiPlDist < nearDist then
    -- do not plan new route if ai reached player
    currentRoute = nil
    internalState.road = 'onroad'
    return
  end

  if currentRoute then
    local curPlan = currentRoute.plan
    local playerNodeInPath = waypointInPath(currentRoute.path, playerNode, curPlan[2].pathidx) or false

    local planVec = curPlan[2].pos - curPlan[1].pos
    local playerIncoming = playerSpeed >= 3 and playerNode == wp1 and aiPlDist < max(ai.speed, playerSpeed) and playerVel:dot(planVec) < 0 -- player is driving towards or past ai on the ai segment
    local playerBehind = playerSpeed >= 3 and planVec:dot(playerVel) > 0 and ai.dirVec:dot(aiPosRear - player.pos) > 0 -- player got passed by ai
    local playerOtherWay = not playerNodeInPath and planVec:dot(positions[playerNode] - ai.pos) < 0 and (playerSpeed < 3 or playerVel:dot(player.pos - ai.pos) > 0) -- player is driving other way from ai

    local route
    if not playerNodeInPath and not internalState.chaseData.driveAhead and (ai.speed < 3 or ai.dirVec:dot(player.pos - ai.pos) > 0) then -- prevents ai from cancelling its current route if it should slow down to turn around
      local path = mapData:getChasePath(wp1, wp2, plwp1, plwp2, ai.pos, ai.vel, player.pos, player.vel, opt.driveInLaneFlag and 1e4 or 1)

      route = planAhead(path, currentRoute) -- ignore current route if path should go other way
      if route and route.plan then --and tempPlan.targetSpeed >= min(ai.speed, curPlan.targetSpeed) and (tempPlan.targetPos-curPlan.targetPos):dot(ai.dirVec) >= 0 then
        currentRoute = route
      end
    end

    local pathLen = getPathLen(currentRoute.path, playerNodeInPath or math.huge) -- curPlan[2].pathidx
    local playerMinPlanLen = getMinPlanLen(0, playerSpeed)
    if M.mode == 'chase' and pathLen < playerMinPlanLen then -- ai chase path should be extended
      local pathCount = #currentRoute.path
      local fleePath = mapData:getFleePath(currentRoute.path[pathCount], playerVel, player.pos, playerMinPlanLen, 0, 0)
      if fleePath[2] ~= wp1 and fleePath[2] ~= wp2 and fleePath[2] ~= currentRoute.path[pathCount - 1] then -- only extend the path if it does not do a u-turn
        pathExtend(currentRoute.path, fleePath)
      end
    end

    if not route then
      planAhead(currentRoute)
    end

    local targetSpeed

    if M.mode == 'chase' then
      local brakeDist = square(ai.speed) / (2 * g * aggression)
      local relSpeed = playerVel:dot(ai.dirVec)
      local crashSpeed = 10 -- minimum relative crash speed
      if aiPlDist < max(brakeDist, nearDist) and ai.dirVec:dot(aiPosRear - player.pos) < 0 then
        targetSpeed = max(crashSpeed, relSpeed + crashSpeed)
        internalState.chaseData.targetSpeed = targetSpeed
      end
    end

    if not internalState.chaseData.driveAhead then
      if playerIncoming or playerOtherWay then -- come to a stop, then plan to turn around
        targetSpeed = 0
      elseif playerBehind then -- match the player speed based on distance
        targetSpeed = clamp(playerSpeed * (1 - aiPlDist / 120), 5, max(5, curPlan[2].speed))
      end
    end
    curPlan.targetSpeed = targetSpeed or curPlan.targetSpeed

    if M.mode == 'chase' then
      internalState.road = 'onroad'

      if playerIncoming then -- player is head on versus ai
        internalState.road = 'tail'
      elseif aiPlDist < 25 and ai.dirVec:dot((ai.pos - ai.dirVec * ai.length) - player.pos) < 0 then -- player is near ai, but ai path does a u-turn
        local uTurn = false
        for i, p in ipairs(currentRoute.path) do -- detect path u-turn
          if p == playerNode then break end
          if i > 2 and ai.dirVec:dot(positions[p] - positions[currentRoute.path[i - 1]]) < 0 then
            uTurn = true
            break
          end
        end
        if uTurn then
          -- cast a ray to see if ai can directly attack player without hitting a barrier
          if obj:castRayStatic(ai.pos + ai.upVec * 0.5, (ai.pos - player.pos) / (aiPlDist + 1e-30), aiPlDist) >= aiPlDist then
            internalState.road = 'tail'
            if isAtPlayerSeg then -- important to reset the route here
              currentRoute = nil
              return
            end
          end
        end
      end
      if not playerIncoming and (plwp2 == currentRoute.path[curPlan[2].pathidx] or plwp2 == currentRoute.path[curPlan[2].pathidx + 1]) then -- player is matching ai target node
        local playerNodePos1 = positions[plwp2]
        local segDir = playerNodePos1 - positions[plwp1]
        local targetLineDir = vec3(-segDir.y, segDir.x, 0); targetLineDir:normalize()
        local xnorm1 = closestLinePoints(playerNodePos1, playerNodePos1 + targetLineDir, player.pos, player.pos + player.dirVec)
        local xnorm2 = closestLinePoints(playerNodePos1, playerNodePos1 + targetLineDir, ai.pos, ai.pos + ai.dirVec)
        -- player xnorm and ai xnorm get interpolated here
        local tarPos = playerNodePos1 + targetLineDir * clamp(lerp(xnorm1, xnorm2, 0.5), -radii[plwp2], radii[plwp2])

        local p2Target = tarPos - player.pos; p2Target:normalize()
        local plVel2Target = playerSpeed > 0.1 and player.vel:dot(p2Target) or 0
        local plTimeToTarget = tarPos:distance(player.pos) / (plVel2Target + 1e-30)

        local aiVel2Target = ai.speed > 0.1 and ai.vel:dot((tarPos - ai.pos):normalized()) or 0
        local aiTimeToTarget = tarPos:distance(ai.pos) / (aiVel2Target + 1e-30)

        if aiTimeToTarget < plTimeToTarget and not playerBehind then
          internalState.road = 'tail'
        end
      end
    end

    if internalState.chaseData.playerState == 'stopped' then
      currentRoute.plan.targetSpeed = 0
    end
  else
    local path
    if M.mode == 'chase' and ai.dirVec:dot(playerVel) > 0 and ai.dirVec:dot(aiPosRear - player.pos) > 0 then
      path = mapData:getFleePath(wp2, playerVel, player.pos, getMinPlanLen(100, ai.speed), 0, 0)
      internalState.chaseData.driveAhead = true
    else
      path = mapData:getChasePath(wp1, wp2, plwp1, plwp2, ai.pos, ai.vel, player.pos, player.vel, opt.driveInLaneFlag and 1e4 or 1)
      internalState.chaseData.driveAhead = false
    end

    local route = planAhead(path)
    if route and route.plan then
      currentRoute = route
    end
  end
end

M.pullOver = false
local function setPullOver(val)
  M.pullOver = val
end

local function trafficActions()
  if not currentRoute then return end
  local path, plan = currentRoute.path, currentRoute.plan

  -- horn
  if parameters.enableElectrics and trafficStates.action.hornTimer == 0 then
    electrics.horn(true)
    trafficStates.action.hornTimerLimit = max(0.1, math.random())
  end
  if trafficStates.action.hornTimer >= trafficStates.action.hornTimerLimit then
    electrics.horn(false)
    trafficStates.action.hornTimer = -1
  end

  if trafficStates.action.hornTimer >= 0 then
    trafficStates.action.hornTimer = trafficStates.action.hornTimer + dt
  end

  local pullOver = false
  pullOver = M.pullOver

  -- hazard lights
  if beamstate.damage >= 1000 then
    if recover.recoverOnCrash then
      recover._recoverOnCrash = true
    else
      if electrics.values.signal_left_input == 0 and electrics.values.signal_right_input == 0 then
        electrics.set_warn_signal(1)
      end
      pullOver = true
    end
  end

  -- pull over
  local minSirenSqDist = math.huge
  local nearestPoliceId

  for plID, v in pairs(mapmgr.getObjects()) do
    if plID ~= objectId and v.states then
      if v.states.lightbar == 2 or (v.states.lightbar == 1 and v.vel:squaredLength() >= 100) then
        local posFront = obj:getObjectFrontPosition(plID)
        minSirenSqDist = min(minSirenSqDist, posFront:squaredDistance(ai.pos))
        nearestPoliceId = plID
      end
    end
  end
  if minSirenSqDist <= 10000 then
    pullOver = true
    trafficStates.action.nearestPoliceId = nearestPoliceId
  end

  if trafficStates.action.nearestPoliceId then
    local police = mapmgr.objects[trafficStates.action.nearestPoliceId]
    if police and police.states and police.states.lightbar then
      if ai.speed < 10 and ai.pos:squaredDistance(police.pos) < 400 and (ai.pos - police.pos):normalized():dot(police.dirVec) > 0.94 then
        pullOver = true -- vehicle stays pulled over in this case, and other traffic may keep driving
      end
    end
  end

  if pullOver and not trafficStates.action.forcedStop and ai.speed >= 3 then
    local brakeDist = square(ai.speed) / (2 * g * aggression)
    local dist = max(10, brakeDist)
    local idx = getLastNodeWithinDistance(plan, dist)
    local n = plan[idx]
    local side = mapmgr.rules.rightHandDrive and -1 or 1
    local disp = n.pos:distance(n.posOrig + n.normal * side * (n.halfWidth - ai.width * 0.5))
    trafficStates.side.displacement = disp
    --dist = dist + disp * 4 -- arbitrary extra distance?

    laneChange(plan, max(10, dist - 20), disp * side)
    setStopPoint(plan, dist, {avoidJunction = true})
    trafficStates.action.forcedStop = true
    trafficStates.side.side = mapmgr.rules.rightHandDrive and -1 or 1
  end

  if not pullOver and trafficStates.action.forcedStop then
    --laneChange(plan, 40, -trafficStates.side.displacement) -- this is no longer needed?
    setStopPoint()
    trafficStates.action.forcedStop = false
    trafficStates.action.nearestPoliceId = nil
  end

  if trafficStates.action.forcedStop and ai.speed < min(plan.targetSpeed or 0, 1) then -- instant plan stop
    setStopPoint(plan, 0)
  end

  -- Search for controlled (traffic light or stop sign) or uncontrolled (right of way) intersections along the path
  local tSi = trafficStates.intersection
  if not tSi.node then
    tSi.block = false

    tSi.startIdx = tSi.startIdx or (plan[1].wp and plan[1].pathidx-1 or plan[1].pathidx)
    for i = tSi.startIdx, #path - 1 do -- TODO: would searching up to min(#path-1, plan[plan.planCount].pathIdx) work to distribute the load over more frames work?
      local nid1, nid2 = path[i], path[i + 1]
      if not nid1 then
        nid1 = plan[1].wp -- just in case the ai is at the very start of the plan
      end

      if nid1 and nid2 then
        -- if trafficStates.intersection.prevNode == nid1 then break end -- vehicle is still within previous intersection

        local n1Pos, n2Pos = mapData.positions[nid1], mapData.positions[nid2]

        -- *****Controlled intersection (traffic light or stop sign)******
        if signalsData and signalsData[nid1] and signalsData[nid1][nid2] then -- nodes from current path match the signals dict
            -- TODO: check the array for the ideal signal to use
            -- lane check as well, if applicable
          local bestSignal = signalsData[nid1][nid2][1]

          local nDir = n2Pos - n1Pos
          nDir.z = 0
          nDir:normalize()
          table.clear(tSi)
          tSi.node = nid1
          tSi.nextNode = nid2
          tSi.nodeIdx = 1
          tSi.pos = bestSignal.pos
          tSi.dir = nDir
          tSi.action = bestSignal.action
          tSi.block = false
          tSi.controlled = true

          -- adding turnDir
          if path[i + 2] then
            local n3Pos = mapData.positions[path[i + 2]]
            if tableSize(mapData.graph[nid2]) > 2 then -- if next path node is not in the middle of the junction
              tSi.turnDir = n3Pos - n2Pos
              tSi.turnDir.z = 0
              tSi.turnDir:normalize()
              tSi.turnNode = nid2
            else
              if path[i + 3] then
                tSi.turnDir = mapData.positions[path[i + 3]] - n3Pos
                tSi.turnDir.z = 0
                tSi.turnDir:normalize()
                tSi.turnNode = path[i + 2]
              end
            end
          end

        end

        -- *****detect uncontrolled intersection or set the turn direction for an already detected controlled intersection******
        if tableSize(mapData.graph[nid1]) > 2 and not tSi.node and tSi.startIdx > 0 then
          -- we should try to get the effective curvature of the path after this point to determine turn signals

          -- Get Direction Vector of edge exiting nid1
          local linkDir = vec3(); linkDir:setSub2(mapData:getEdgePositions(nid2, nid1))
          linkDir.z = 0
          linkDir:normalize()

          -- Get path Direction Vector to nid1
          local prevNode = path[i-1] or plan[1].wp
          local nDir = vec3()
          local drivability = 1
          if mapData.graph[nid1][prevNode] then
            nDir:setSub2(mapData:getEdgePositions(nid1, prevNode))
            nDir.z = 0
            nDir:normalize()
            drivability = mapData.graph[nid1][prevNode].drivability
          else
            prevNode = nil
            nDir:set(ai.dirVec)
          end

          -- Give way if the direction change at nid1 is greater than 45 deg and less than 135 deg
          -- or if the current path edge leading to nid1 has drivability lower than other roads incident on nid1
          local giveWay = abs(nDir:dot(linkDir)) < 0.707

          if not giveWay and drivability < 1 then
            for _, edgeData in pairs(mapData.graph[nid1]) do
              if edgeData.drivability > drivability then
                giveWay = true
                break
              end
            end
          end

          if giveWay then
            local fourthNode -- the fourth node in a T-junction (the other three nodes being prevNode, nid1, nid2)
            -- the prevNode check is to make sure one of the three roads of the T-Junction is the one the vehicle is comming from
            if prevNode and tableSize(mapData.graph[nid1]) == 3 then
              for k, v in pairs(mapData.graph[nid1]) do
                if k ~= prevNode and k ~= nid2 then
                  fourthNode = k
                end
              end
            end

            -- Checks if the vehicle has right of way in this T-junction
            local side = mapmgr.rules.rightHandDrive and -1 or 1
            local nContinuation = fourthNode and roadNaturalContinuation(fourthNode, nid1)
            local dotDir = side*gravityDir:cross(nDir):dot(linkDir)
            if not (fourthNode and nContinuation ~= nid2 and dotDir > 0) then

              local pos = n1Pos - nDir * (max(3, mapData.radius[nid1]) + 2) --needs at least + 3

              table.clear(tSi)
              tSi.node = nid1
              tSi.nextNode = nid2
              tSi.turnNode = nid1
              tSi.turnDir = linkDir
              tSi.pos = pos
              tSi.dir = nDir
              tSi.action = 3
              tSi.block = false
              -- tSi.fullGiveWay -> giveWay to both left + right
              -- tSi.oneGiveWay -> giveWay only on (right) side
              -- tSi.otherGiveWay -> giveWay only on (left) side
              if fourthNode then
                tSi.fullGiveWay = nContinuation == nid2
                if not tSi.fullGiveWay then
                  tSi.oneGiveWay = dotDir < 0
                else
                  if dotDir > 0 then
                    tSi.fullGiveWay = false
                    tSi.otherGiveWay = true
                  end
                end
              else
                tSi.oneGiveWay = true
              end
            end
          end
        end
      end
      tSi.startIdx = i + 1

      if tSi.node then

        tSi.turn = 0
        tSi.timer = 0
        if tSi.turnDir then
          if abs(tSi.dir:dot(tSi.turnDir)) < 0.707 then
            tSi.turn = -sign2(tSi.dir:cross(gravityDir):dot(tSi.turnDir))
          end
        end

        break
      end
    end
  end

  -- Manage stopping at found intersections
  if tSi.node and not trafficStates.action.forcedStop then
    local signalsRef = tSi.nodeIdx and signalsData[tSi.node][tSi.nextNode][tSi.nodeIdx]
    if signalsRef then
      tSi.action = signalsRef.action or 0 -- get action from referenced table
    else
      tSi.action = tSi.action or 0 -- default action ("go")
    end
    --local sColor = tSi.action == 0 and color(0,255,0,160) or color(255,255,0,160)
    --obj.debugDrawProxy:drawSphere(1, tSi.pos, sColor)
    --obj.debugDrawProxy:drawText(tSi.pos + vec3(0, 0, 1), color(0,0,0,255), tostring(tSi.turn))

    local stopSeg = math.huge
    local brakeDist = square(ai.speed) / (2 * g * ai.staticFrictionCoef * min(1, aggression * 1.3))
    local distSq = ai.pos:squaredDistance(tSi.pos)

    if not tSi.proximity then -- checks if intersection was reached (needs improvement)
      tSi.proximity = distSq <= 400
    end

    if tSi.pos:dot(tSi.dir) + 4 * tSi.dir:dot(tSi.dir) >= ai.pos:dot(tSi.dir)  then -- vehicle position is at the stop pos (with extra distance, to be safe)
      if tSi.action == 3 or tSi.action == 2 or (tSi.action == 1 and (square(brakeDist) < distSq or tSi.commitStopOnYellow)) then -- red light or other stop condition
        local bestDist = 100
        for i = 1, plan.planCount - 1 do -- get best plan node to set as a stopping point
          -- currently checks every frame due to plan segment updates
          -- positional check is used due to issues with using plan.pathidx or complex intersections
          -- it would be great to improve this in the future
          local dist = plan[i].pos:squaredDistance(tSi.pos)
          if dist < bestDist then
            bestDist = dist
            stopSeg = i
          end
        end
        if stopSeg < math.huge and tSi.action == 1 then
          tSi.commitStopOnYellow = true
        end
      end

      if tSi.action == 3 or tSi.action == 2 then
        if stopSeg <= 2 and ai.speed <= 1 then -- stopped at stopping point
          tSi.timer = tSi.timer + dt
          -- if on an uncontrolled intersection, check if there are any vehicles around. if there aren't then continue.
          if tSi.action == 3 then
            local vehicleInRange = false
            local vPosF = vec3()
            local aiCenterPos = getObjectBoundingBox(objectId)
            local distToJcenter = tSi.turnNode and ai.pos:distance(mapData.positions[tSi.turnNode]) or 1
            for vId, v in pairs(mapmgr.getObjects()) do
              if vId ~= objectId then
                local vC, vX = getObjectBoundingBox(vId)
                vPosF:setAdd2(vC, vX)

                -- checkDirRad: v is outside a slice of +-45 degrees and is under a thredshold distance
                local check = false
                local checkDirRad
                if not isVehicleStopped(v) and v.dirVec:dot(vPosF-(ai.pos + distToJcenter*ai.dirVec)) < 0 then
                  checkDirRad = v.dirVec:dot(tSi.dir) < 0.707 and aiCenterPos:squaredDistance(vPosF) < square(max(min(60, max(40, v.vel:squaredLength() / (g * ai.staticFrictionCoef))), v.vel:length()*4))
                end
                -- Different tests for each kind of stop (controlled or fullGiveway/oneGiveWay/otherGiveWay)
                if checkDirRad then
                  if tSi.oneGiveWay then
                    local vFxnorm = tSi.turnDir and vPosF:xnormOnLine(tSi.pos, tSi.pos + 1.5*mapData.radius[tSi.turnNode or tSi.node]*tSi.turnDir) or 0
                    if vFxnorm > 0 and vFxnorm < 1 and v.dirVec:dot(tSi.dir) < -0.707 then
                      check = true
                    end
                  elseif tSi.otherGiveWay or tSi.turn == (mapmgr.rules.rightHandDrive and -1 or 1) then -- other or stop/full but turning to right
                    if tSi.turnDir and v.dirVec:dot(tSi.turnDir) > 0.707 then
                      check = true
                    end
                  else
                    check = true
                  end
                end

                if check then
                  vehicleInRange = true
                  local kr = tSi.controlled and parameters.delayFactorWaitTime[1] or parameters.delayFactorWaitTime[2]
                  local ks = 0.9
                  tSi.timer = tSi.timer - (kr + min(v.vel:squaredLength(),1)*(ks - kr)/1)*dt
                  tSi.timer = max(tSi.timer, 0)
                  break
                end
              end
            end
            if not vehicleInRange then
              tSi.timer = parameters.trafficWaitTime
            end
          end
        end

        if tSi.timer >= parameters.trafficWaitTime then
          if tSi.action == 2 then
            -- Turn on red allowed (right turn for RHT (LHD) and left turn for LHT (RHD) allowed after stopping and intersection is clear)
            if mapmgr.rules.turnOnRed and tSi.turn == (mapmgr.rules.rightHandDrive and -1 or 1) then
              tSi.nodeIdx = nil
              tSi.action = 0
            end
          else
            tSi.nodeIdx = nil
            tSi.action = 0
          end
        end
      end
    else
      if tSi.proximity then
        tSi.nodeIdx = nil
        tSi.action = 0
        if distSq > 400 then -- assumes that vehicle has cleared the intersection (20 m away from the signal point)
          -- temp data until next intersection search
          -- resync startIdx if it has fallen behind by the time the intersection is cleared.
          local startIdx = tSi.startIdx
          if plan[1].pathidx < plan[2].pathidx then -- plan[1] node is on a different path index than the node ahead of it
            -- skip path node if it is behind vehicle
            startIdx = max(startIdx, plan[1].pathidx)
          else
            startIdx = max(startIdx, plan[1].pathidx-1)
          end
          table.clear(tSi)
          tSi.timer = 0
          tSi.turn = 0
          tSi.block = false
          --tSi.prevNode = tSi.node
          tSi.startIdx = startIdx
        end
      end
    end

    plan.stopSeg = stopSeg
    if parameters.enableElectrics and tSi.turnNode and ai.pos:squaredDistance(mapData.positions[tSi.turnNode]) < square(max(50, brakeDist * 1.2)) then -- approaching intersection
      if tSi.turn < 0 and electrics.values.turnsignal >= 0 then
        electrics.toggle_left_signal()
      elseif tSi.turn > 0 and electrics.values.turnsignal <= 0 then
        electrics.toggle_right_signal()
      end
    end
  end
end

local function trafficPlan()
  --profilerPushEvent('ai_trafficPlan_pathfinding')
  if trafficStates.block.block then
    trafficStates.block.timer = trafficStates.block.timer + dt
  else
    trafficStates.block.timer = trafficStates.block.timer * 0.8
    trafficStates.block.hornFlag = false
  end

  if currentRoute and currentRoute.path[1] and not currentRoute.plan.reRoute and trafficStates.block.timer <= trafficStates.block.timerLimit then --and not currentRoute.plan.noExit
    local plan = currentRoute.plan
    local path = currentRoute.path
    if (internalState.road ~= 'offroad' and plan.planLen + getPathLen(path, plan[plan.planCount].pathidx) < getMinPlanLen()) or not path[plan[plan.planCount].pathidx+2] then
      local pathCount = #path

      local newPath
      newPath = mapData:getPathTWithState(path[pathCount], mapData.positions[path[pathCount]], getMinPlanLen(100), trafficPathState[1] and trafficPathState or ai.dirVec)
      table.clear(trafficPathState)
      for i, v in ipairs(newPath) do trafficPathState[i] = v end

      pathExtend(path, newPath)
    end
  else
    local wp1, wp2 = mapmgr.findBestRoad(ai.pos, ai.dirVec)

    if wp1 == nil or wp2 == nil then
      guihooks.message("Could not find a road network, or closest road is too far", 5, "AI debug")
      currentRoute = nil
      internalState.road = 'offroad'
      internalState.changePlanTimer = 0
      driveCar(0, 0, 0, 1)
      return
    end

    local radius = mapData.radius
    local position = mapData.positions
    local graph = mapData.graph

    local dirVec
    if trafficStates.block.timer > trafficStates.block.timerLimit and not graph[wp1][wp2].oneWay and (radius[wp1] + radius[wp2]) * 0.5 > ai.length then
      dirVec = -ai.dirVec -- tries to plan reverse direction
    else
      dirVec = ai.dirVec
    end

    wp1, wp2 = pickAiWp(wp1, wp2, dirVec)

    local path
    path = mapData:getPathTWithState(wp1, ai.pos, getMinPlanLen(80), ai.dirVec)
    table.clear(trafficPathState)
    for i, v in ipairs(path) do trafficPathState[i] = v end

    if path[2] == wp2 and path[3] then
      local xnorm = ai.pos:xnormOnLine(position[wp1], position[wp2])
      if xnorm >= 0 and xnorm <= 1 and (position[wp2] - position[wp1]):dot(ai.dirVec) < 0 then
        -- vehicle is within the first path segment but facing the wrong way
        table.remove(path, 1)
      end
    end
    ai.currentSegment[1] = wp1
    ai.currentSegment[2] = wp2

    if path and path[1] then
      local route = planAhead(path, currentRoute)

      if route and route.plan then
        trafficStates.block.timerLimit = max(1, parameters.trafficWaitTime * 2)

        table.clear(trafficStates.intersection)
        trafficStates.intersection.timer = 0
        trafficStates.intersection.turn = 0
        trafficStates.intersection.block = false

        if trafficStates.block.timer > trafficStates.block.timerLimit and trafficStates.action.hornTimer == -1 then
          trafficStates.block.timer = 0
          if not trafficStates.block.hornFlag then
            trafficStates.action.hornTimer = 0 -- activates horn
            trafficStates.block.hornFlag = true -- prevents horn from triggering again while stopped
          end

          currentRoute = route
          return
        elseif not currentRoute then
          currentRoute = route
          return
        elseif route.plan.targetSpeed >= min(currentRoute.plan.targetSpeed, ai.speed) and targetsCompatible(currentRoute, route) then
          currentRoute = route
          return
        end
      end
    end
  end
  --profilerPopEvent('ai_trafficPlan_pathfinding')

  --profilerPushEvent('ai_trafficActions')
  trafficActions()
  --profilerPopEvent('ai_trafficActions')

  --profilerPushEvent('ai_planAhead')
  planAhead(currentRoute)
  --profilerPopEvent('ai_planAhead')
end

local function warningAIDisabled(message)
  guihooks.message(message, 5, "AI debug")
  M.mode = 'disabled'
  M.updateGFX = nop
  resetMapAndRoute()
  stateChanged()
end

local function targetFollowControl(targetSpeed, distLim) -- throttle and brake control for ai directly going to player
  -- distLim: Minimum distance allowed

  -- local targetPos, throttleTargetSpeed, brakeTargetSpeed <-- WIP
  if not targetSpeed then
    if not player or not player.pos then return 0, 0, 0 end
    local plC, plX, plY, plZ = getObjectBoundingBox(player.id)
    local ai2PlDirVec = plC - ai.pos; ai2PlDirVec:normalize()
    local minHit = intersectsRay_OBB(ai.pos, ai2PlDirVec, plC, plX, plY, plZ)
    local plSpeedFromAI = player.vel:dot(ai2PlDirVec)
    local ai2PlDist = minHit - (distLim or 3)
    targetSpeed = sqrt(max(0, abs(plSpeedFromAI) * plSpeedFromAI + 2 * g * min(aggression, ai.staticFrictionCoef) * ai2PlDist))

    -- WIP
    -- throttleTargetSpeed = sqrt(max(0, abs(plSpeedFromAI) * plSpeedFromAI + 2 * g * min(aggression, ai.staticFrictionCoef) * (minHit - (distLim or 3) - ai.speed * 1)))
    -- brakeTargetSpeed = sqrt(max(0, abs(plSpeedFromAI) * plSpeedFromAI + 2 * g * min(aggression * 1.5, ai.staticFrictionCoef) * (minHit - (distLim or 3))))
    -- targetPos = catmullRomChordal(ai.pos-ai.dirVec, ai.pos, plC-plX, plC-plX+plX:normalized(), min(1, max(ai.speed * parameters.lookAheadKv, 4.5) / ai.pos:distance(plC - plX)))
    -- obj.debugDrawProxy:drawSphere(0.25, targetPos, color(255, 0, 0, 255))
    -- obj.debugDrawProxy:drawSphere(0.25, plC-plX, color(0, 0, 255, 255))
    -- obj.debugDrawProxy:drawSphere(0.15, ai.pos + brakeTargetSpeed * ai.upVec, color(255, 0, 0, 255))
    -- obj.debugDrawProxy:drawSphere(0.15, ai.pos + throttleTargetSpeed * ai.upVec, color(0, 255, 0, 255))
    -- obj.debugDrawProxy:drawSphere(0.15, ai.pos + ai.speed * ai.upVec, color(0, 0, 255, 255))
  end

  local speedDif = targetSpeed - ai.speed
  return clamp(speedDif, 0, 1), clamp(-speedDif, 0, 1), targetSpeed

  -- WIP
  --return clamp((throttleTargetSpeed - ai.speed) * 0.25, 0, 1), clamp(ai.speed - brakeTargetSpeed, 0, 1), brakeTargetSpeed, targetPos
end

local function drivabilityChangeReroute()
  -- Description: handle changes in edge drivabilities
  -- This function compares the current ai path for collisions with the drivability change set
  -- if there is an edge along the current path that had its drivability decreased
  -- a flag is raised (currentRoute.plan.reRoute) then handled by the appropriate planner

  if currentRoute ~= nil then
    -- changeSet format: {nodeA1, nodeB1, driv1, nodeA2, nodeB2, driv2, ...}
    local changeSet = mapmgr.changeSet
    local changeSetCount = #changeSet
    local changeSetDict = table.new(0, 2 * (changeSetCount / 3))

    -- populate the changeSetDict with the changeSet nodes
    for i = 1, changeSetCount, 3 do
      if changeSet[i+2] < 0 then
        changeSetDict[changeSet[i]] = true
        changeSetDict[changeSet[i+1]] = true
      end
    end

    local path = currentRoute.path
    local nodeCollisionIdx
    for i = currentRoute.plan[2].pathidx, #path do
      if changeSetDict[path[i]] then
        -- if there is a collision continue with a thorough check (edges against edges)
        nodeCollisionIdx = i
        break
      end
    end

    if nodeCollisionIdx then
      table.clear(changeSetDict)
      local edgeTab = {'','\0',''}
      -- populate the changeSetDict with changeSet edges
      for i = 1, changeSetCount, 3 do
        if changeSet[i+2] < 0 then
          local nodeA, nodeB = changeSet[i], changeSet[i+1]
          edgeTab[1] = nodeA < nodeB and nodeA or nodeB
          edgeTab[3] = nodeA == edgeTab[1] and nodeB or nodeA
          changeSetDict[tableConcat(edgeTab)] = true
        end
      end

      local edgeCollisionIdx
      -- compare path edges with changeSetDict edges starting with the earliest edge containing the initialy detected node collision
      for i = max(currentRoute.plan[2].pathidx, nodeCollisionIdx - 1), #path-1 do
        local nodeA, nodeB = path[i], path[i+1]
        edgeTab[1] = nodeA < nodeB and nodeA or nodeB
        edgeTab[3] = nodeA == edgeTab[1] and nodeB or nodeA
        if changeSetDict[tableConcat(edgeTab)] then
          edgeCollisionIdx = i
          currentRoute.plan.reRoute = edgeCollisionIdx
          break
        end
      end

      -- if edgeCollisionIdx then
      --   -- find closest possible diversion point from edgeCollisionIdx
      --   local graph = mapData.graph
      --   for i = edgeCollisionIdx, currentRoute.plan[2].pathidx, -1 do
      --     local node = path[i]
      --     if tableSize(graph[node]) > 2 then

      --     end
      --   end
      --   dump(objectId, edgeCollisionIdx, path[edgeCollisionIdx], path[edgeCollisionIdx+1])
      -- end
    end
  end
end

local function getSafeTeleportPosRot()
  if currentRoute and currentRoute.path and currentRoute.path[2] then
    local pathIdx = #currentRoute.path
    local node = currentRoute.path[pathIdx]
    local pos = mapData.positions[node]

    local node2 = currentRoute.path[pathIdx-1]
    local pos2 = mapData.positions[node2]

    local dir = (pos - pos2):normalized()
    local up = mapmgr.surfaceNormalBelow(pos)
    local rot = quatFromDir(-dir:cross(up):cross(up), up) -- minus sign is due to convention used by safeTeleport

    if not mapData.graph[node][node2].oneway then
      -- if not a one way road shift the position to the right by half the road radius (ie. 1/4 of the width)
      pos = pos + dir:cross(up):normalized() * (mapData.radius[node] * 0.5)
    end

    return pos, rot
  end
end

M.updateGFX = nop
local function updateGFX(dtGFX)
  dt = dtGFX
  if traffic.rateQue > 0 then
    traffic.frameQue = traffic.frameQue + 1
  end

  if mapData ~= mapmgr.mapData then
    currentRoute = nil
  end

  if mapmgr.changeSet then
    drivabilityChangeReroute()
    mapmgr.changeSet = nil
  end

  mapData = mapmgr.mapData
  signalsData = mapmgr.signalsData

  if mapData == nil then return end

  ai.pos:set(obj:getFrontPosition())
  ai.pos.z = max(ai.pos.z - 1, obj:getSurfaceHeightBelow(ai.pos))
  ai.prevDirVec:set(ai.dirVec)
  ai.dirVec:set(obj:getDirectionVectorXYZ())
  ai.upVec:set(obj:getDirectionVectorUpXYZ())
  ai.rightVec:setCross(ai.dirVec, ai.upVec); ai.rightVec:normalize()
  ai.vel:set(obj:getSmoothRefVelocityXYZ())
  ai.speed = ai.vel:length()
  ai.width = ai.width or obj:getInitialWidth()
  ai.length = ai.length or obj:getInitialLength()
  ai.staticFrictionCoef = parameters.staticFrictionCoefMult * obj:getStaticFrictionCoef() -- depends on ground model, tire and tire load

  if lastCommand.throttle > 0.5 and ai.speed < 1 then
    internalState.aiCannotMoveTime = internalState.aiCannotMoveTime + dt
  else
    internalState.aiCannotMoveTime = 0
  end

  if ai.speed < 3 then
    trafficStates.side.cTimer = trafficStates.side.cTimer + dt
    trafficStates.side.timer = (trafficStates.side.timer + dt) % (2 * trafficStates.side.timerLimit)
    trafficStates.side.side = sign2(trafficStates.side.timerLimit - trafficStates.side.timer)
  else
    trafficStates.side.cTimer = max(0, trafficStates.side.cTimer - dt)
    trafficStates.side.timer = 0
    trafficStates.side.side = 1
  end

  if recover.recoverOnCrash then
    if ai.speed < 3 then
      recover.recoverTimer = recover.recoverTimer + dt
    else
      recover.recoverTimer = max(0, recover.recoverTimer - 5 * dt)
    end
    if recover._recoverOnCrash or recover.recoverTimer > 60 then
      recover._recoverOnCrash = false
      recover.recoverTimer = 0
      local pos, rot = getSafeTeleportPosRot()
      if pos then
        obj:queueGameEngineLua(
          "map.safeTeleport(" .. obj:getId() .. ", " .. pos.x .. ", " .. pos.y .. ", " .. pos.z .. ", " .. rot.x .. ", " .. rot.y .. ", " .. rot.z .. ", " .. rot.w .. ", nil, nil, true, true, true)"
        )
        return
      end
    end
  end

  internalState.changePlanTimer = max(0, internalState.changePlanTimer - dt)

  -- local wp1, wp2 = mapmgr.findClosestRoad(ai.pos)
  -- if (mapData.positions[wp2] - mapData.positions[wp1]):dot(ai.dirVec) > 0 then
  --   wp1, wp2 = wp2, wp1
  -- end
  -- ai.currentSegment = {wp1, wp2}
  ai.currentSegment[1] = nil
  ai.currentSegment[2] = nil

  ------------------ RANDOM MODE ----------------
  if M.mode == 'random' then
    local route
    if not currentRoute or currentRoute.plan.reRoute or currentRoute.plan.planLen + getPathLen(currentRoute.path, currentRoute.plan[currentRoute.plan.planCount].pathidx) < getMinPlanLen() then
      local wp1, wp2 = mapmgr.findClosestRoad(ai.pos)
      if wp1 == nil or wp2 == nil then
        warningAIDisabled("Could not find a road network, or closest road is too far")
        return
      end
      ai.currentSegment[1] = wp1
      ai.currentSegment[2] = wp2

      if internalState.road == 'offroad' then
        local vec1 = mapData.positions[wp1] - ai.pos
        local vec2 = mapData.positions[wp2] - ai.pos
        if ai.dirVec:dot(vec1) > 0 and ai.dirVec:dot(vec2) > 0 then
          if vec1:squaredLength() > vec2:squaredLength() then
            wp1, wp2 = wp2, wp1
          end
        elseif ai.dirVec:dot(mapData.positions[wp2] - mapData.positions[wp1]) > 0 then
          wp1, wp2 = wp2, wp1
        end
      elseif ai.dirVec:dot(mapData.positions[wp2] - mapData.positions[wp1]) > 0 then
        wp1, wp2 = wp2, wp1
      end

      local path = mapData:getRandomPath(wp1, wp2, opt.driveInLaneFlag and 1e4 or 1)

      if path and path[1] then
        local route = planAhead(path, currentRoute)
        if route and route.plan then
          if not currentRoute then
            currentRoute = route
          else
            local curPlanIdx = currentRoute.plan[2].pathidx
            local curPathCount = #currentRoute.path
            if curPlanIdx >= curPathCount * 0.9 or (targetsCompatible(currentRoute, route) and route.plan.targetSpeed >= ai.speed) then
              currentRoute = route
            end
          end
        end
      end
    end

    if currentRoute ~= route then
      planAhead(currentRoute)
    end

  ------------------ TRAFFIC MODE ----------------
  elseif M.mode == 'traffic' then
    --profilerPushEvent('ai_trafficPlan')
    trafficPlan()
    --profilerPopEvent('ai_trafficPlan')

  ------------------ MANUAL MODE ----------------
  elseif M.mode == 'manual' then
    if validateInput(wpList or manualPath) then
      newManualPath()
    elseif scriptData then
      setScriptedPath(scriptData)
      scriptData = nil
    end

    if opt.aggressionMode == 'rubberBand' then
      updatePlayerData()
      if player ~= nil then
        if (ai.pos - player.pos):dot(ai.dirVec) > 0 then
          setAggressionInternal(max(min(0.1 + max((150 - player.pos:distance(ai.pos))/150, 0), M.extAggression), 0.5))
        else
          setAggressionInternal()
        end
      end
    end

    planAhead(currentRoute)

  ------------------ SPAN MODE ------------------
  elseif M.mode == 'span' then
    if currentRoute == nil then
      local positions = mapData.positions
      local wpAft, wpFore = mapmgr.findClosestRoad(ai.pos)
      if not (wpAft and wpFore) then
        warningAIDisabled("Could not find a road network, or closest road is too far")
        return
      end
      if ai.dirVec:dot(positions[wpFore] - positions[wpAft]) < 0 then wpAft, wpFore = wpFore, wpAft end

      ai.currentSegment[1] = wpFore
      ai.currentSegment[2] = wpAft

      local target, targetLink

      if not (edgeDict and edgeDict[1]) then
        -- creates the edgeDict and returns a random edge
        target, targetLink = getMapEdges(M.cutOffDrivability or 0, wpFore)
        if not target then
          warningAIDisabled("No available target with selected characteristics")
          return
        end
      end

      local path = {}
      while true do
        if not target then
          local maxDist = -math.huge
          local lim = 1
          repeat
            -- get most distant non walked edge
            for k, v in pairs(edgeDict) do
              if v <= lim then
                if lim > 1 then edgeDict[k] = 1 end
                local i = string.find(k, '\0')
                local n1id = string.sub(k, 1, i-1)
                local sqDist = positions[n1id]:squaredDistance(ai.pos)
                if sqDist > maxDist then
                  maxDist = sqDist
                  target = n1id
                  targetLink = string.sub(k, i+1, #k)
                end
              end
            end
            lim = math.huge -- if the first iteration does not produce a target
          until target
        end

        local nodeDegree = 1
        for lid, _ in pairs(mapData.graph[target]) do
          -- we're looking for neighboring nodes other than the targetLink
          if lid ~= targetLink then
            nodeDegree = nodeDegree + 1
          end
        end
        if nodeDegree == 1 then
          local key = target..'\0'..targetLink
          edgeDict[key] = edgeDict[key] + 1
        end

        path = mapData:spanMap(wpFore, wpAft, target, edgeDict, opt.driveInLaneFlag and 1e7 or 1)

        if not path[2] and wpFore ~= target then
          -- remove edge from edgeDict list and get a new target (while loop will iterate again)
          edgeDict[target..'\0'..targetLink] = nil
          edgeDict[targetLink..'\0'..target] = nil
          target = nil
          if next(edgeDict) == nil then
            warningAIDisabled("Could not find a path to any of the possible targets")
            return
          end
        elseif not path[1] then
          warningAIDisabled("No Route Found")
          return
        else
          -- insert the second edge node in newRoute if it is not already contained
          local pathCount = #path
          if path[pathCount-1] ~= targetLink then path[pathCount+1] = targetLink end
          break
        end
      end

      local route = planAhead(path)
      if not route then return end
      currentRoute = route
    else
      planAhead(currentRoute)
    end

  ------------------ FLEE MODE ------------------
  elseif M.mode == 'flee' then
    updatePlayerData()
    if player then
      if validateInput() then
        targetWPName = wpList[1]
        wpList = nil
      end

      fleePlan()

      if internalState.road == 'offroad' then
        local targetPos = ai.pos + (ai.pos - player.pos) * 100
        local targetSpeed = math.huge
        driveToTarget(targetPos, 1, 0, targetSpeed)
        return
      end
    else
      -- guihooks.message("No vehicle to Flee from", 5, "AI debug") -- TODO: this freezes the up because it runs on the gfx step
      return
    end

  ------------------ CHASE MODE ------------------
  elseif M.mode == 'chase' or M.mode == 'follow' then
    updatePlayerData()
    if player then
      chasePlan()

      if internalState.road == 'tail' then
        --internalState.road = 'onroad'
        --currentRoute = nil
        local plai = player.pos - ai.pos
        local relvel = ai.vel:dot(plai) - player.vel:dot(plai)

        local throttle, brake, targetSpeed = targetFollowControl(internalState.chaseData.targetSpeed or math.huge)
        if relvel > 0 then
          driveToTarget(player.pos + (plai:length() / (relvel + 1e-30)) * player.vel, throttle, brake, targetSpeed)
        else
          driveToTarget(player.pos, throttle, brake, targetSpeed)
        end
        return
      elseif internalState.road == 'offroad' then
        local throttle, brake, targetSpeed = targetFollowControl(M.mode == 'chase' and math.huge)
        driveToTarget(player.pos, throttle, brake, targetSpeed)
        return
      elseif currentRoute == nil then
        driveCar(0, 0, 0, 1)
        return
      end

    else
      -- guihooks.message("No vehicle to Chase", 5, "AI debug")
      return
    end

  ------------------ STOP MODE ------------------
  elseif M.mode == 'stop' then
    if currentRoute then
      planAhead(currentRoute)
      local targetSpeed = max(0, ai.speed - sqrt(max(0, square(ai.staticFrictionCoef * g) - square(sensors.gx2))) * dt) -- TODO: check this calculation, i don't think it does what you think it does
      currentRoute.plan.targetSpeed = min(currentRoute.plan.targetSpeed, targetSpeed)
    elseif ai.vel:dot(ai.dirVec) > 0 then
      driveCar(0, 0, 0.5, 0)
    else
      driveCar(0, 1, 0, 0)
    end
    if ai.speed < 0.08 then
      driveCar(0, 0, 0, 1)
      M.mode = 'disabled'
      M.manualTargetName = nil
      M.updateGFX = nop
      resetMapAndRoute()
      stateChanged()
      if controller.mainController and restoreGearboxMode then
        controller.mainController.setGearboxMode('realistic')
      end
      return
    end
  end
  -----------------------------------------------

  if currentRoute then
    local plan = currentRoute.plan
    local targetPos = plan.targetPos
    local aiSeg = plan.aiSeg

    -- cleanup path if it has gotten too long
    if not loopPath and plan[aiSeg].pathidx >= 10 and currentRoute.path[20] then
      local path = currentRoute.path
      local k = plan[aiSeg].pathidx - 2
      for i = 1, #path do
        path[i] = path[k+i]
      end
      for i = 1, plan.planCount do
        plan[i].pathidx = plan[i].pathidx - k
      end
      -- sync lane change indices
      currentRoute.lastLaneChangeIdx = currentRoute.lastLaneChangeIdx - k
      for _, v in ipairs(currentRoute.laneChanges) do
        v.pathIdx = v.pathIdx - k
      end
      local pathDistK = currentRoute.pathLength[k+1]
      for i = 1, #currentRoute.pathLength do
        currentRoute.pathLength[i] = currentRoute.pathLength[k+i] and currentRoute.pathLength[k+i] - pathDistK or nil
      end
      -- sync trafficState intersection search index
      if trafficStates and trafficStates.intersection and trafficStates.intersection.startIdx then
        trafficStates.intersection.startIdx = trafficStates.intersection.startIdx - k
        -- if trafficStates.intersection.startIdx < 1 then
        --   trafficStates.intersection.startIdx = nil
        -- end
      end
    end

    local targetSpeed = plan.targetSpeed

    if ai.upVec:dot(gravityDir) >= -0.2588 then -- vehicle upside down
      driveCar(0, 0, 0, 0)
      return
    end

    local lowTargetSpeedVal = 0.24
    if not plan[aiSeg+2] and ((targetSpeed < lowTargetSpeedVal and ai.speed < 0.15) or (targetPos - ai.pos):dot(ai.dirVec) < 0) then
      if M.mode == 'span' then
        local path = currentRoute.path
        for i = 1, #path - 1 do
          local key = path[i]..'\0'..path[i+1]
          -- in case we have gone over an edge that is not in the edgeDict list
          edgeDict[key] = edgeDict[key] and (edgeDict[key] * 20)
        end
      end

      if ai.speed < 0.15 then
        driveCar(0, 0, 0, 1)
        aistatus('route done', 'route')
        if dataLogger.logData ~= nop then
          startStopDataLog()
        end
        guihooks.message("Route done", 5, "AI debug")
        currentRoute = nil
      else
        driveCar(0, 0, max(0.3, lastCommand.brake), 0)
      end
      return
    end

    -- come off controls when close to intermediate node with zero speed (ex. intersection), arcade autobrake takes over
    if (plan[aiSeg+1].speed == 0 and plan[aiSeg+2]) and ai.speed < 0.15 then
      driveCar(0, 0, 0, 0)
      return
    end

    if electrics.values.ignitionLevel == 3 then
      if ai.speed < 1.5 then
        driveCar(0, 0, 0, 1)
      end
      return
    end

    if ai.speed < 0.1 and targetSpeed > 0.5 and (lastCommand.throttle ~= 0 or lastCommand.brake ~= 0) and twt.state == 0 and
    not (controller.isFrozen or electrics.values['transbrake'] or (trafficStates.intersection.action == 3 or trafficStates.intersection.action == 2)) then

      if internalState.crash.time == 0 then
        internalState.crash.pos = ai.pos:copy()
      end
      internalState.crash.time = internalState.crash.time + dt
      if internalState.crash.time > 1 then
        local diff = ai.pos:squaredDistance(internalState.crash.pos)
        if  diff < 0.1*0.1 then
          if recover.recoverOnCrash then
            recover._recoverOnCrash = true
            internalState.crash.time = 0
          else
            internalState.crash.dir = vec3(ai.dirVec)
            internalState.crash.manoeuvre = 1
          end
        else
          internalState.crash.time = 0
        end
      end
    end

    -- Throttle and Brake control
    local speedDif = targetSpeed - ai.speed
    local rate = targetSpeedDifSmoother[speedDif > 0 and targetSpeedDifSmoother.state >= 0 and speedDif >= targetSpeedDifSmoother.state]
    speedDif = targetSpeedDifSmoother:getWithRate(speedDif, dt, rate)

    local legalSpeedDif = plan.targetSpeedLegal - ai.speed
    local lowSpeedDif = min(speedDif - clamp((ai.speed - 2) * 0.5, 0, 1), legalSpeedDif) * parameters.throttleKp
    local lowTargSpeedConstBrake = lowTargetSpeedVal - targetSpeed -- apply constant brake below some targetSpeed

    local throttle = clamp(lowSpeedDif, 0, 1) * sign(max(0, -lowTargSpeedConstBrake)) -- throttle not enganged for targetSpeed < 0.26

    local brakeLimLow = sign(max(0, lowTargSpeedConstBrake)) * 0.5

    local brake = sign(max(0, (electrics.values.smoothShiftLogicAV or 0) - 3))
    if plan.sideDisp and opt.racing then
      local speedDifH = targetSpeed/sqrt(min(1, aggression)) - ai.speed
      brake = clamp(-speedDifH, brakeLimLow, 1) * brake  -- arcade autobrake comes in at |smoothShiftLogicAV| < 5
    else
      brake = clamp(-speedDif, brakeLimLow, 1) * brake -- arcade autobrake comes in at |smoothShiftLogicAV| < 5
    end

    if brake > 0 and abs(speedDif) < 0.5 and lastCommand.throttle == 0 and lastCommand.brake == 0 then
      -- check if deceleration without braking is larger or equal to the desired deceleration
      if sensors.gy2 >= (square(plan[1].speed) - square(plan[2].speed)) / (2 * plan[1].length) then
        brake = 0
      end
    end

    driveToTarget(targetPos, throttle, brake)
  end

  dataLogger.logData()
end

local function debugDraw(focusPos)
  local debugDrawer = obj.debugDrawProxy

  if M.mode == 'script' and scriptai ~= nil then
    scriptai.debugDraw()
  end

  if currentRoute then
    local plan = currentRoute.plan
    local targetPos = plan.targetPos
    local targetSpeed = plan.targetSpeed

    if targetPos then
      debugDrawer:drawSphere(0.25, targetPos, color(255,0,0,255))

      local aiSeg = plan.aiSeg
      local shadowPos = currentRoute.plan[aiSeg].pos + plan.aiXnormOnSeg * (plan[aiSeg+1].pos - plan[aiSeg].pos)
      local blue = color(0,0,255,255)
      debugDrawer:drawSphere(0.25, shadowPos, blue)

      for vehId in pairs(mapmgr.getObjects()) do
        if vehId ~= objectId then
          debugDrawer:drawSphere(0.25, obj:getObjectFrontPosition(vehId), blue)
        end
      end

      if player then
        debugDrawer:drawSphere(0.3, player.pos, color(0,255,0,255))
      end
    end

    if M.debugMode == 'target' then
      if mapData and mapData.graph and currentRoute.path then
        local p = mapData.positions[currentRoute.path[#currentRoute.path]]
        debugDrawer:drawSphere(4, p, color(255,0,0,100))
        debugDrawer:drawText(p + vec3(0, 0, 4), color(0,0,0,255), 'Destination')
      end

    elseif M.debugMode == 'route' then
      local maxCount = 700
      local last = visDebug.routeRec.last
      local count = min(#visDebug.routeRec, maxCount)
      if count == 0 or visDebug.routeRec[last]:squaredDistance(ai.pos) > (7 * 7) then
        last = 1 + last % maxCount
        visDebug.routeRec[last] = vec3(ai.pos)
        count = min(count+1, maxCount)
        visDebug.routeRec.last = last
      end

      local tmpVec = vec3(0.7, ai.width, 0.7)
      local black = color(0, 0, 0, 128)
      for i = 1, count-1 do
        debugDrawer:drawSquarePrism(visDebug.routeRec[1+(last+i-1)%count], visDebug.routeRec[1+(last+i)%count], tmpVec, tmpVec, black)
      end

      if currentRoute.plan[1].pathidx then
        local positions = mapData.positions
        local path = currentRoute.path
        tmpVec:setAdd(vec3(0, ai.width, 0))
        local transparentRed = color(255, 0, 0, 120)
        for i = currentRoute.plan[1].pathidx, #path - 1 do
          debugDrawer:drawSquarePrism(positions[path[i]], positions[path[i+1]], tmpVec, tmpVec, transparentRed)
        end
      end

      -- Draw candidate paths if available
      if visDebug.candidatePaths and visDebug.candidatePaths[1] then
        local winner = visDebug.candidatePaths.winner
        local source = visDebug.candidatePaths[1][1] -- all paths have the same source node
        debugDrawer:drawSphere(2, mapData.positions[source], color(0, 0, 0, 255))
        for i = 1, #visDebug.candidatePaths do
          local thisPath = visDebug.candidatePaths[i]
          local thisPathCount = #thisPath
          local thisScore = visDebug.candidatePaths[i].score
          for i = 1, thisPathCount-1 do
            debugDrawer:drawCylinder(mapData.positions[thisPath[i]], mapData.positions[thisPath[i+1]], 0.5, jetColor(thisScore, 200))
          end
          local thisPathLastNode = thisPath[thisPathCount]
          debugDrawer:drawSphere(4, mapData.positions[thisPathLastNode], jetColor(thisScore, 255))
          if thisPathLastNode == winner then
            debugDrawer:drawCylinder(mapData.positions[thisPathLastNode], mapData.positions[thisPathLastNode] + vec3(0, 0, 8), 2, color(0, 0, 0, 255))
          end
          local txt = thisPathLastNode.." -> "..strFormat("%0.4f", thisScore)
          debugDrawer:drawText(mapData.positions[thisPathLastNode] + vec3(0, 0, 2), color(0, 0, 0, 255), txt)
        end
      else
        -- Mark destination node in current path
        if currentRoute.path then
          local p = mapData.positions[currentRoute.path[#currentRoute.path]]
          debugDrawer:drawSphere(4, p, color(255, 0, 0, 100))
          debugDrawer:drawText(p + vec3(0, 0, 4), color(0, 0, 0, 255), 'Destination')
        end
      end

    elseif M.debugMode == 'speeds' then
      -- Debug Throttle brake application
      local maxCount = 175
      local count = min(#visDebug.trajecRec, maxCount)
      local last = visDebug.trajecRec.last
      if count == 0 or visDebug.trajecRec[last][1]:squaredDistance(ai.pos) > (0.2 * 0.2) then
        last = 1 + last % maxCount
        visDebug.trajecRec[last] = {vec3(ai.pos), ai.speed, targetSpeed, lastCommand.brake, lastCommand.throttle}
        count = min(count+1, maxCount)
        visDebug.trajecRec.last = last
      end

      local tmpVec1 = vec3(0.7, ai.width, 0.7)
      for i = 1, count-1 do
        local n = visDebug.trajecRec[1 + (last + i) % count]
        debugDrawer:drawSquarePrism(visDebug.trajecRec[1 + (last + i - 1) % count][1], n[1], tmpVec1, tmpVec1, color(255 * sqrt(abs(n[4])), 255 * sqrt(n[5]), 0, 100))
      end

      local prevEntry
      local zOffSet = vec3(0, 0, 0.4)
      local yellow, blue = color(255,255,0,200), color(0,0,255,200)
      local tmpVec2 = vec3()
      for i = 1, count-1 do
        local v = visDebug.trajecRec[1 + (last + i - 1) % count]
        if prevEntry then
          -- actuall speed
          tmpVec1:set(0, 0, prevEntry[2] * 0.2)
          tmpVec2:set(0, 0, v[2] * 0.2)
          debugDrawer:drawCylinder(prevEntry[1] + tmpVec1, v[1] + tmpVec2, 0.02, yellow)

          -- target speed
          tmpVec1:set(0, 0, prevEntry[3] * 0.2)
          tmpVec2:set(0, 0, v[3] * 0.2)
          debugDrawer:drawCylinder(prevEntry[1] + tmpVec1, v[1] + tmpVec2, 0.02, blue)
        end

        tmpVec1:set(0, 0, v[3] * 0.2)
        debugDrawer:drawCylinder(v[1], v[1] + tmpVec1, 0.01, blue)

        if focusPos:squaredDistance(v[1]) < visDebug.labelRenderDistance * visDebug.labelRenderDistance then
          tmpVec1:set(0, 0, v[2] * 0.2)
          debugDrawer:drawText(v[1] + tmpVec1 + zOffSet, yellow, strFormat("%2.0f", v[2]*3.6).." kph")

          tmpVec1:set(0, 0, v[3] * 0.2)
          debugDrawer:drawText(v[1] + tmpVec1 + zOffSet, blue, strFormat("%2.0f", v[3]*3.6).." kph")
        end
        prevEntry = v
      end

      -- Planned speeds
      if plan[1] then
        local red = color(255,0,0,200) -- getContrastColor(objectId)
        local black = color(0, 0, 0, 255)
        local green = color(0, 255, 0, 200)
        local prevSpeed = -1
        local prevLegalSpeed = -1
        local prevPoint = plan[1].pos
        local prevPoint_ = plan[1].pos
        local tmpVec = vec3()
        for i = 1, #plan do
          local n = plan[i]

          local speed = (n.speed >= 0 and n.speed) or prevSpeed
          tmpVec:set(0, 0, speed * 0.2)
          local p1 = n.pos + tmpVec
          debugDrawer:drawCylinder(n.pos, p1, 0.03, red)
          debugDrawer:drawCylinder(prevPoint, p1, 0.05, red)
          debugDrawer:drawText(p1, black, strFormat("%2.0f", speed*3.6).." kph")
          prevSpeed = speed
          prevPoint = p1

          if M.speedMode == 'legal' then
            local legalSpeed = (n.legalSpeed >= 0 and n.legalSpeed) or prevLegalSpeed
            tmpVec:set(0, 0, legalSpeed * 0.2)
            local p1_ = n.pos + tmpVec
            debugDrawer:drawCylinder(n.pos, p1_, 0.03, green)
            debugDrawer:drawCylinder(prevPoint_, p1_, 0.05, green)
            debugDrawer:drawText(p1_, black, strFormat("%2.0f", legalSpeed*3.6).." kph")
            prevLegalSpeed = legalSpeed
            prevPoint_ = p1_
          end

          --[[
          if traffic and traffic[i] then
            for _, data in ipairs(traffic[i]) do
              local plPosOnPlan = linePointFromXnorm(n.pos, plan[i+1].pos, data[2])
              debugDrawer:drawSphere(0.25, plPosOnPlan, color(0,255,0,100))
            end
          end
          --]]
        end

        ---[[ Debug road width and lane limits
        local prevPointOrig = plan[1].posOrig
        local tmpVec = vec3(1, 1, 1)
        local tmpVec1 = vec3(0.5, 0.5, 0.5)

        for i = 1, #plan do
          local n = plan[i]
          local p1Orig = n.posOrig - n.biNormal
          debugDrawer:drawCylinder(n.posOrig, p1Orig, 0.03, black)
          debugDrawer:drawCylinder(p1Orig, p1Orig + n.normal, 0.03, black)
          debugDrawer:drawCylinder(prevPointOrig, p1Orig, 0.03, black)
          local roadHalfWidth = n.halfWidth
          --debugDrawer:drawCylinder(n.posOrig, p1Orig, roadHalfWidth, color(255, 0, 0, 40))
          if n.laneLimLeft and n.laneLimRight then -- You need to uncomment the appropriate code in planAhead force integrator loop for this to work
            debugDrawer:drawSquarePrism(n.pos - (n.lateralXnorm - n.laneLimLeft) * n.normal, n.pos + (n.laneLimRight - n.lateralXnorm) * n.normal, tmpVec, tmpVec, color(0,0,255,120))
          end
          if n.rangeLeft and n.rangeRight then
            local rangeLeft = linearScale(n.rangeLeft, 0, 1, -roadHalfWidth, roadHalfWidth)
            local rangeRight = linearScale(n.rangeRight, 0, 1, -roadHalfWidth, roadHalfWidth)
            debugDrawer:drawSquarePrism(n.posOrig + rangeLeft * n.normal, n.posOrig + rangeRight * n.normal, tmpVec1, tmpVec1, color(255,0,0,120))
          end
          prevPointOrig = p1Orig
        end
        --]]

        --[[ Debug lane change. You need to uncomment upvalue newPositionsDebug for this to work
        if newPositionsDebug[1] then
          local green = color(0,255,0,200)
          local prevPoint = newPositionsDebug[1]
          for i = 1, #newPositionsDebug do
            local pos = newPositionsDebug[i]
            local p1 = pos + vec3(0, 0, 2)
            debugDrawer:drawCylinder(pos, p1, 0.03, green)
            debugDrawer:drawCylinder(prevPoint, p1, 0.05, green)
            prevPoint = p1
          end
        end
        --]]

        for i = max(1, plan[1].pathidx-2), #currentRoute.path-2 do
          local wp1 = currentRoute.path[i]
          local wp2 = currentRoute.path[i+1]
          if tableSize(mapData.graph[wp2]) > 2 then
            local minNode = roadNaturalContinuation(wp1, wp2)
            if minNode and minNode ~= currentRoute.path[i+2] then
              debugDrawer:drawCylinder(mapData.positions[wp2], mapData.positions[minNode], 0.2, black)
            end
          end
        end
      end

      -- Player segment visual debug for chase / follow mode
      -- if internalState.chaseData.playerRoad then
      --   local col1, col2
      --   if internalState.road == 'tail' then
      --     col1 = color(0,0,0,200)
      --     col2 = color(0,0,0,200)
      --   else
      --     col1 = color(255,0,0,100)
      --     col2 = color(0,0,255,100)
      --   end
      --   local plwp1 = internalState.chaseData.playerRoad[1]
      --   debugDrawer:drawSphere(2, mapData.positions[plwp1], col1)
      --   local plwp2 = internalState.chaseData.playerRoad[2]
      --   debugDrawer:drawSphere(2, mapData.positions[plwp2], col2)
      -- end

    elseif M.debugMode == 'trajectory' then
      -- Debug Curvatures
      -- local plan = currentRoute.plan
      -- if plan ~= nil then
      --   local prevPoint = plan[1].pos
      --   for i = 1, #plan do
      --     local p = plan[i].pos
      --     local v = plan[i].curvature or 1e-10
      --     local scaledV = abs(1000 * v)
      --     debugDrawer:drawCylinder(p, p + vec3(0, 0, scaledV), 0.06, color(abs(min(sign(v),0))*255,max(sign(v),0)*255,0,200))
      --     debugDrawer:drawText(p + vec3(0, 0, scaledV), color(0,0,0,255), strFormat("%5.4e", v))
      --     debugDrawer:drawCylinder(prevPoint, p + vec3(0, 0, scaledV), 0.06, col)
      --     prevPoint = p + vec3(0, 0, scaledV)
      --   end
      -- end

      -- Debug Planned Speeds
      if plan[1] then
        local col = getContrastColor(objectId)
        local prevPoint = plan[1].pos
        local prevSpeed = -1
        local drawLen = 0
        for i = 1, #plan do
          local n = plan[i]
          local p = n.pos
          local v = (n.speed >= 0 and n.speed) or prevSpeed
          local p1 = p + vec3(0, 0, v*0.2)
          --debugDrawer:drawLine(p + vec3(0, 0, v*0.2), (n.pos + n.turnDir) + vec3(0, 0, v*0.2), col)
          debugDrawer:drawCylinder(p, p1, 0.03, col)
          debugDrawer:drawCylinder(prevPoint, p1, 0.05, col)
          debugDrawer:drawText(p1, color(0,0,0,255), strFormat("%2.0f", v*3.6) .. " kph")
          prevPoint = p1
          prevSpeed = v
          drawLen = drawLen + n.vec:length()
          if drawLen > 80 then break end
        end
      end

      -- Debug Throttle brake application
      local maxCount = 175
      local count = min(#visDebug.trajecRec, maxCount)
      local last = visDebug.trajecRec.last
      if count == 0 or visDebug.trajecRec[last][1]:squaredDistance(ai.pos) > (0.25 * 0.25) then
        last = 1 + last % maxCount
        visDebug.trajecRec[last] = {vec3(ai.pos), lastCommand.throttle, lastCommand.brake}
        count = min(count+1, maxCount)
        visDebug.trajecRec.last = last
      end

      local tmpVec = vec3(0.7, ai.width, 0.7)
      for i = 1, count-1 do
        local n = visDebug.trajecRec[1+(last+i)%count]
        debugDrawer:drawSquarePrism(visDebug.trajecRec[1+(last+i-1)%count][1], n[1], tmpVec, tmpVec, color(255 * sqrt(abs(n[3])), 255 * sqrt(n[2]), 0, 100))
      end
    elseif false and M.debugMode == 'rays' then
      local aiScanLength = ai.length * 0.9 --small adjustments for origins to be a bit inside the car
      local aiScanWidth = ai.width * 0.7
      local shiftHorizontalVec = (aiScanWidth * 0.5) * ai.rightVec --creation of horizontal helper vector
      local shiftVerticalVec = -0.05 * ai.length * ai.dirVec --creation of vertical helper vector
      local shiftPerpendicularVec = 0.35 * ai.upVec
      local aiPosElevatedR = ai.pos:copy() --creation of FR corner vector
      aiPosElevatedR:setAdd(shiftHorizontalVec)
      aiPosElevatedR:setAdd(shiftVerticalVec)
      aiPosElevatedR:setAdd(shiftPerpendicularVec) -- elevation, this should work only on flat inclination for now
      local aiPosElevatedL = aiPosElevatedR:copy() --creation of FL corner vector
      shiftHorizontalVec:setScaled(-2)
      aiPosElevatedL:setAdd(shiftHorizontalVec)
      local aiPosBackElevatedL = aiPosElevatedL:copy() --creation of BR corner vector
      shiftVerticalVec:setScaled(aiScanLength * 20/ai.length)
      aiPosBackElevatedL:setAdd(shiftVerticalVec)
      local aiPosBackElevatedR = aiPosElevatedR:copy() --creation of BL corner vector
      aiPosBackElevatedR:setAdd(shiftVerticalVec)

      local rayDist = 4 * ai.wheelBase -- TODO: Optimize rayDist. Higher is better for more open spaces but w performance hit
      populateOBBinRange(rayDist)
      local tmpVec = vec3()
      local helperVec = vec3()
      local rounds = twt.idx - 1
      dump("rounds in debug", rounds)

      for i = twt.idx, rounds do --the ray cast loop: each iteration scans one corner and one side
        i = i % 8 + 1
        local j = i * 4
        tmpVec:setLerp(twt.posTable[twt.RRT[j-3]], twt.posTable[twt.RRT[j-2]], twt.blueNoiseCoef)
        helperVec:setLerp(twt.dirTable[twt.RRT[j-1]], twt.dirTable[twt.RRT[j]], twt.blueNoiseCoef) -- LERP corner direction
        helperVec:normalize()
        local rayLen = castRay(tmpVec, helperVec, min(twt.rayMins[i], rayDist))

        local shiftVec = helperVec * rayLen
        local rayHitPos = tmpVec + shiftVec
        debugDrawer:drawCylinder(tmpVec, rayHitPos, 0.02, color(255,255,255,255))

        if twt.rayMins[i] > rayLen then -- odd index is corners
          twt.minRayCoefs[i] = twt.blueNoiseCoef
          twt.rayMins[i] = rayLen
        else
          tmpVec:setLerp(twt.posTable[twt.RRT[j-3]], twt.posTable[twt.RRT[j-2]], twt.minRayCoefs[i])
          helperVec:setLerp(twt.dirTable[twt.RRT[j-1]], twt.dirTable[twt.RRT[j]], twt.minRayCoefs[i]) -- LERP corner direction
          helperVec:normalize()
          twt.rayMins[i] = castRay(tmpVec, helperVec, min(2 * twt.rayMins[i], rayDist))
        end
      end

      -- debugDrawer:drawSphere(0.3, ai.pos, color(255,255,0,255))
      -- dump(obj)
      -- local test = obj:getCornerPosition(0)
      -- local test2 = obj:getCornerPosition(1)
      -- local test3 = obj:getCornerPosition(2)
      -- local test4 = obj:getCornerPosition(3)
      -- local frontPos = obj:getFrontPosition()

      -- dump(test)
      -- debugDrawer:drawSphere(0.1, frontPos, color(255,255,0,255))
      -- debugDrawer:drawSphere(0.3, test2, color(255,0,0,255))
      -- debugDrawer:drawSphere(0.3, test3, color(255,0,0,255))
      -- debugDrawer:drawSphere(0.3, test4, color(255,0,0,255))
      -- debugDrawer:drawSphere(0.3, test, color(255,0,0,255))
      -- local test2 = obj:getFrontPositionRelative()
      -- dump(test2)
      -- debugDrawer:drawSphere(0.3, ai.wheelBase[2], color(255,255,0,255))
      -- ray origins
      -- debugDrawer:drawSphere(0.1, ai.pos, color(0,0,0,255))
      debugDrawer:drawSphere(0.1, twt.posTable[1], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, twt.posTable[2], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, twt.posTable[3], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, twt.posTable[4], color(255,255,255,255))

      for _, d in pairs(visDebug.debugSpots) do
        debugDrawer:drawSphere(0.2, d[1], d[2])
      end
    end
  end

  if false then
    local c, x, y, z = getObjectBoundingBox(objectId) -- center, front vec, left vec, up vec
    local col = color(255, 0, 0, 255)
    drawOBB(c, x, y, z, col)

    if dt then
      for k, v in pairs(mapmgr.getObjects()) do
        if k ~= objectId then
          --dump(v.pos)
          obj.debugDrawProxy:drawSphere(0.2, v.pos, color(0, 0, 255, 255))
          local vPos = vec3(obj:getObjectFrontPosition(k))
          obj.debugDrawProxy:drawSphere(0.2, vPos, color(0, 0, 255, 255))
          obj.debugDrawProxy:drawSphere(0.2, vPos + v.vel * dt, color(0, 255, 0, 255))
          --dump(obj:getObjectDirectionVector(k))
          --dump(obj:getObjectDirectionVectorUp(k))
        end
      end
    end
    obj.debugDrawProxy:drawSphere(0.15, obj:getFrontPosition(), color(255, 0, 0, 255))
  end

  --[[
  if true then
    -- Draw vehicle ref node, wheel hub positions and wheel contact points (estimates) with ground
    local refNodePos = obj:getPosition()
    debugDrawer:drawSphere(0.1, refNodePos, color(255,0,0,255))
    for _, wheel in pairs(wheels.wheels) do
      local wheelRadius = wheel.radius
      local wheelPosAbsolute = refNodePos + obj:getNodePosition(wheel.node1)
      debugDrawer:drawSphere(0.1, wheelPosAbsolute, color(255,0,0,255))
      local contactPointPos = wheelPosAbsolute - obj:getDirectionVectorUp() * wheelRadius
      debugDrawer:drawSphere(0.1, contactPointPos, color(255,0,0,255))
    end

    -- vehicle frontPos
    local vehFrontPos = obj:getFrontPosition()
    debugDrawer:drawSphere(0.1, obj:getFrontPosition(), color(255, 255, 255, 255))
    -- vehicle frontPos
    debugDrawer:drawSphere(0.1, vehFrontPos:z0(), color(0, 255, 255, 255))

    -- calculated spawn pos (from script front pos)
    debugDrawer:drawSphere(0.1, vec3(736.8858419,102.6078886,0.1169999319), color(0, 0, 255, 255))

    -- script first pos (ground truth)
    debugDrawer:drawSphere(0.1, vec3(734.9434413112983, 102.21897064457461, 1.0), color(255, 0, 255, 255))

    -- Draw world reference Frame
    debugDrawer:drawSphere(0.1, vec3(0, 0, 0), color(0, 255, 0, 255)) -- World 0
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(1, 0, 0), 0.05, color(0, 255, 0, 255)) -- x (green)
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(0, 1, 0), 0.05, color(255, 0, 0, 255)) -- y (red)
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(0, 0, 1), 0.05, color(0, 0, 255, 255)) -- z (blue)
  end
  --]]
end

local function setAvoidCars(v)
  M.extAvoidCars = v
  if M.extAvoidCars == 'off' or M.extAvoidCars == 'on' then
    opt.avoidCars = M.extAvoidCars
  else
    opt.avoidCars = M.mode == 'manual' and 'off' or 'on'
  end
  stateChanged()
end

local function driveInLane(v)
  if v == 'on' then
    M.driveInLaneFlag = 'on'
    opt.driveInLaneFlag = true
  else
    M.driveInLaneFlag = 'off'
    opt.driveInLaneFlag = false
  end
  stateChanged()
end

local function setVehicleDebugMode(newMode)
  tableMerge(M, newMode)
  if M.debugMode ~= 'trajectory' then
    visDebug.trajecRec = {last = 0}
  end
  if M.debugMode ~= 'route' then
    visDebug.routeRec = {last = 0}
  end
  if M.debugMode ~= 'speeds' then
    visDebug.trajecRec = {last = 0}
  end
  if M.debugMode ~= 'rays' then
    visDebug.trajecRec = {last = 0}
  end
  if M.debugMode ~= 'off' then
    M.debugDraw = debugDraw
  else
    M.debugDraw = nop
  end
end

local function setMode(mode)
  if tableSizeC(wheels.wheels) == 0 then return end
  if mode ~= nil then
    if M.mode ~= mode then -- new AI mode is not the same as the old one
      obj:queueGameEngineLua('onAiModeChange('..objectId..', "'..mode..'")')
    end
    M.mode = mode
  end

  if M.extAvoidCars == 'off' or M.extAvoidCars == 'on' then
    opt.avoidCars = M.extAvoidCars
  else
    opt.avoidCars = (M.mode == 'manual' and 'off' or 'on')
  end

  if M.mode ~= 'script' then
    if M.mode ~= 'disabled' and M.mode ~= 'stop' then
      resetMapAndRoute()

      mapmgr.requestMap()
      M.updateGFX = updateGFX
      targetSpeedDifSmoother:set(0)
      targetSpeedSmoother:set(ai.speed)

      if controller.mainController then
        if electrics.values.gearboxMode == 'realistic' then
          restoreGearboxMode = true
        end
        controller.mainController.setGearboxMode('arcade')
      end

      ai.wheelBase = calculateWheelBase()

      if M.mode == 'flee' or M.mode == 'chase' or M.mode == 'follow' then
        setAggressionMode('rubberBand')
      end

      if M.mode == 'traffic' then
        setSpeedMode('legal')
        driveInLane('on')
        setTractionModel(1)
        setSpeedProfileMode('Back')
        obj:setSelfCollisionMode(2)
        obj:setAerodynamicsMode(2)
      else
        setTractionModel(2)
        obj:setSelfCollisionMode(1)
        obj:setAerodynamicsMode(1)
      end
    end

    if M.mode == 'disabled' then
      driveCar(0, 0, 0, 0)
      M.updateGFX = nop
      currentRoute = nil
      if controller.mainController and restoreGearboxMode then
        controller.mainController.setGearboxMode('realistic')
      end
    end

    stateChanged()
    sounds.updateObjType()
  end

  visDebug.trajecRec = {last = 0}
  visDebug.routeRec = {last = 0}
end

local function setRecoverOnCrash(val)
  recover.recoverOnCrash = val
end

local function toggleTrafficMode()
  if M.mode == "traffic" then
    setMode("disabled")
    setRecoverOnCrash(false)
  else
    setMode("traffic")
    setRecoverOnCrash(true)
  end
end

local function reset() -- called when the user pressed I
  M.manualTargetName = nil
  resetInternalStates()

  throttleSmoother:set(0)
  smoothTcs:set(1)

  if M.mode ~= 'disabled' then
    driveCar(0, 0, 0, 0)
    setMode() -- some scenarios don't work if this is changed to setMode('disabled')
  end
  stateChanged()

  if dataLogger.logData ~= nop then
    startStopDataLog()
  end
end

local function resetLearning()
end

local function setState(newState)
  if tableSizeC(wheels.wheels) == 0 then return end

  if newState.mode and newState.mode ~= M.mode then -- new AI mode is not the same as the old one
    obj:queueGameEngineLua('onAiModeChange('..objectId..', "'..newState.mode..'")')
  end

  local mode = M.mode
  tableMerge(M, newState)
  setAggressionExternal(M.extAggression)

  -- after a reload (cntr-R) vehicle should be left with handbrake engaged if ai is disabled
  -- preserve initial state of vehicle controls (handbrake engaged) if current mode and new mode are both 'disabled'
  if not (mode == 'disabled' and M.mode == 'disabled') then
    setMode()
  end

  setVehicleDebugMode(M)
  setTargetObjectID(M.targetObjectID)
  stateChanged()
end

local function setTarget(wp)
  M.manualTargetName = wp
  validateInput = validateUserInput
  wpList = {wp}
end

local function setPath(path)
  manualPath = path
  validateInput = validateUserInput
end

local function driveUsingPath(arg)
  --[[ At least one argument of either path or wpTargetList or script must be specified. All other arguments are optional.

  * path: A sequence of waypoint names that form a path by themselves to be followed in the order provided.
  * wpTargetList: A sequence of waypoint names to be used as succesive targets ex. wpTargetList = {'wp1', 'wp2'}.
                  Between any two consequitive waypoints a shortest path route will be followed.
  * script: A sequence of positions

  -- Optional Arguments --
  * wpSpeeds: Type: (key/value pairs, key: "node_name", value: speed, number in m/s)
              Define target speeds for individual waypoints. The ai will try to meet this speed when at the given waypoint.
  * noOfLaps: Type: number. Default value: nil
              The number of laps if the path is a loop. If not defined, the ai will just follow the succesion of waypoints once.
  * routeSpeed: A speed in m/s. To be used in tandem with "routeSpeedMode".
                Type: number
  * routeSpeedMode: Values: 'limit': the ai will not go above the 'routeSpeed' defined by routeSpeed.
                            'set': the ai will try to always go at the speed defined by "routeSpeed".
  * driveInLane: Values: 'on' (anything else is considered off/inactive)
                 When 'on' the ai will keep on the correct side of the road on two way roads.
                 This also affects pathFinding in that when this option is active ai paths will traverse roads in the legal direction if posibble.
                 Default: inactive
  * aggression: Value: 0.3 - 1. The aggression value with which the ai will drive the route.
                At 1 the ai will drive at the limit of traction. A value of 0.3 would be considered normal every day driving, going shopping etc.
                Default: 0.3
  * avoidCars: Values: 'on' / 'off'.  When 'on' the ai will be aware of (avoid crashing into) other vehicles on the map. Default is 'off'
  * examples:
  ai.driveUsingPath{ wpTargetList = {'wp1', 'wp10'}, driveInLane = 'on', avoidCars = 'on', routeSpeed = 35, routeSpeedMode = 'limit', wpSpeeds = {wp1 = 10, wp2 = 40}, aggression = 0.3}
  In the above example the speeds set for wp1 and wp2 will take precedence over "routeSpeed" for the specified nodes.
  --]]

  if (arg.wpTargetList == nil and arg.path == nil and arg.script == nil) or
    (type(arg.wpTargetList) ~= 'table' and type(arg.path) ~= 'table' and type(arg.script) ~= 'table') or
    (arg.wpSpeeds ~= nil and type(arg.wpSpeeds) ~= 'table') or
    (arg.noOfLaps ~= nil and type(arg.noOfLaps) ~= 'number') or
    (arg.routeSpeed ~= nil and type(arg.routeSpeed) ~= 'number') or
    (arg.routeSpeedMode ~= nil and type(arg.routeSpeedMode) ~= 'string') or
    (arg.driveInLane ~= nil and type(arg.driveInLane) ~= 'string') or
    (arg.aggression ~= nil and type(arg.aggression) ~= 'number')
  then
    return
  end

  if arg.script then
    -- Set vehicle position and orientation at the start of the path
    -- Get initial position and orientation of vehicle at start of path (possibly time offset and/or time delayed)
    local script = arg.script
    local dir, up, pos
    if script[1].dir then
      -- vehicle initial orientation vectors exist

      dir = vec3(script[1].dir)
      up = vec3(script[1].up or mapmgr.surfaceNormalBelow(vec3(script[1])))

      local frontPosRelOrig = obj:getOriginalFrontPositionRelative() -- original relative front position in the vehicle coordinate system (left, back, up)
      local vx = dir * -frontPosRelOrig.y
      local vz = up * frontPosRelOrig.z
      local vy = dir:cross(up) * -frontPosRelOrig.x
      pos = vec3(script[1]) - vx - vz - vy
      local dH = require('scriptai').wheelToGroundDist(pos, dir, up)
      pos:setAdd(dH * up)
    else
      -- vehicle initial orientation vectors don't exist
      -- estimate vehicle orientation vectors from path and ground normal

      local p1 = vec3(script[1])
      local p1z0 = p1:z0()
      local scriptPosi = vec3()
      local k
      for i = 2, #script do
        scriptPosi:set(script[i].x, script[i].y, 0)
        if p1z0:squaredDistance(scriptPosi) > 0.2 * 0.2 then
          k = i
          break
        end
      end

      if k then
        local p2 = vec3(script[k])
        dir = p2 - p1; dir:normalize()
        up = mapmgr.surfaceNormalBelow(p1)

        local frontPosRelOrig = obj:getOriginalFrontPositionRelative() -- original relative front position in the vehicle coordinate system (left, back, up)
        local vx = dir * -frontPosRelOrig.y
        local vz = up * frontPosRelOrig.z
        local vy = dir:cross(up) * -frontPosRelOrig.x
        pos = p1 - vx - vz - vy
        local dH = require('scriptai').wheelToGroundDist(pos, dir, up)
        pos:setAdd(dH * up)
      end
    end

    if dir then
      local rot = quatFromDir(dir:cross(up):cross(up), up)
      obj:queueGameEngineLua(
        "getObjectByID(" .. objectId .. "):resetBrokenFlexMesh();" ..
        "vehicleSetPositionRotation(" .. objectId .. "," .. pos.x .. "," .. pos.y .. "," .. pos.z .. "," .. rot.x .. "," .. rot.y .. "," .. rot.z .. "," .. rot.w .. ")"
      )

      mapmgr.setCustomMap() -- nils mapmgr.mapData
      M.mode = 'manual'
      stateChanged()

      local pathMap = require('graphpath').newGraphpath()
      local path = {}
      local radius = obj:getInitialWidth()
      local outNode, outPos
      local speedProfile = {}
      for i = 1, #arg.script - 1 do
        local inNode = 'wp_'..tostring(i)
        outNode = 'wp_'..tostring(i+1)
        local inPos = vec3(arg.script[i].x, arg.script[i].y, arg.script[i].z)
        outPos = vec3(arg.script[i+1].x, arg.script[i+1].y, arg.script[i+1].z)
        pathMap:uniEdge(inNode, outNode, inPos:distance(outPos), 1, arg.script[i].vl or 100, nil, false)
        pathMap:setPointPositionRadius(inNode, inPos, arg.script[i].r or radius)
        table.insert(path, inNode)
        speedProfile[inNode] = arg.script[i].v
      end
      pathMap:setPointPositionRadius(outNode, outPos, radius)
      table.insert(path, 'wp_'..tostring(#arg.script))
      speedProfile[outNode] = arg.script[#arg.script].v

      scriptData = deepcopy(arg)
      scriptData.mapData = pathMap
      scriptData.path = path
      scriptData.speedProfile = speedProfile
    end
  else
    setState({mode = 'manual'})

    setParameters({ -- setParameters calls tableMerge so the nil guards are not really needed
      driveStyle = arg.driveStyle or 'default',
      staticFrictionCoefMult = arg.staticFrictionCoefMult,
      lookAheadKv = max(0.1, arg.lookAheadKv or parameters.lookAheadKv),
      understeerThrottleControl = arg.understeerThrottleControl,
      oversteerThrottleControl = arg.oversteerThrottleControl,
      throttleTcs = arg.throttleTcs,
      abBrakeControl = arg.abBrakeControl,
      underSteerBrakeControl = arg.underSteerBrakeControl,
      throttleKp = arg.throttleKp,
      targetSpeedSmootherRate = arg.targetSpeedSmootherRate,
      turnForceCoef = arg.turnForceCoef,
      springForceIntegratorDispLim = arg.springForceIntegratorDispLim
    })

    noOfLaps = arg.noOfLaps and max(arg.noOfLaps, 1) or 1
    wpList = arg.wpTargetList
    manualPath = arg.path
    validateInput = validateUserInput
    opt.avoidCars = arg.avoidCars or 'off'

    if noOfLaps > 1 and ((wpList and wpList[2] and wpList[1] == wpList[#wpList]) or (manualPath and manualPath[2] and manualPath[1] == manualPath[#manualPath])) then
      loopPath = true
    end

    speedProfile = arg.wpSpeeds or {}
    setSpeed(arg.routeSpeed)
    setSpeedMode(arg.routeSpeedMode)

    driveInLane(arg.driveInLane)

    setAggressionExternal(arg.aggression)
    stateChanged()
  end
end

local function spanMap(cutOffDrivability)
  M.cutOffDrivability = cutOffDrivability or 0
  setState({mode = 'span'})
  stateChanged()
end

local function setCutOffDrivability(drivability)
  M.cutOffDrivability = drivability or 0
  stateChanged()
end

local function onDeserialized(v)
  setState(v)
  stateChanged()
end

local function dumpCurrentRoute()
  dump(currentRoute)
end

local function getParameters()
  return parameters
end

local function startRecording(recordSpeed)
  M.mode = 'script'
  scriptai = require("scriptai")
  scriptai.startRecording(recordSpeed)
  M.updateGFX = scriptai.updateGFX
end

local function stopRecording()
  M.mode = 'disabled'
  scriptai = require("scriptai")
  local script = scriptai.stopRecording()
  M.updateGFX = scriptai.updateGFX
  return script
end

local function startFollowing(...)
  local script = ...
  if script.path then
    script = script.path
  end
  if script[1] and script[1].v then
    driveUsingPath({script = script})
  else
    M.mode = 'script'
    scriptai = require("scriptai")
    scriptai.startFollowing(...)
    M.updateGFX = scriptai.updateGFX
  end
end

local function scriptStop(...)
  M.mode = 'disabled'
  scriptai = require("scriptai")
  scriptai.scriptStop(...)
  M.updateGFX = scriptai.updateGFX
end

local function scriptState()
  scriptai = require("scriptai")
  return scriptai.scriptState()
end

local function setScriptDebugMode(mode)
  scriptai = require("scriptai")
  if mode == nil or mode == 'off' then
    M.debugMode = 'all'
    M.debugDraw = nop
    return
  end

  M.debugDraw = debugDraw
  scriptai.debugMode = mode
end

local function isDriving()
  return M.updateGFX == updateGFX or (scriptai ~= nil and scriptai.isDriving())
end


-- public interface
M.driveInLane = driveInLane
M.stateChanged = stateChanged
M.reset = reset
M.setMode = setMode
M.toggleTrafficMode = toggleTrafficMode
M.setAvoidCars = setAvoidCars
M.setTarget = setTarget
M.setPath = setPath
M.setSpeed = setSpeed
M.setSpeedMode = setSpeedMode
M.setParameters = setParameters
M.getParameters = getParameters
M.setVehicleDebugMode = setVehicleDebugMode
M.setState = setState
M.getState = getState
M.debugDraw = nop
M.driveUsingPath = driveUsingPath
M.setAggressionMode = setAggressionMode
M.setAggression = setAggressionExternal
M.onDeserialized = onDeserialized
M.setTargetObjectID = setTargetObjectID
M.laneChange = laneChange
M.setStopPoint = setStopPoint
M.dumpCurrentRoute = dumpCurrentRoute
M.spanMap = spanMap
M.setCutOffDrivability = setCutOffDrivability
M.resetLearning = resetLearning
M.isDriving = isDriving
M.startStopDataLog = startStopDataLog
M.setRecoverOnCrash = setRecoverOnCrash
M.getEdgeLaneConfig = getEdgeLaneConfig
M.setPullOver = setPullOver
M.roadNaturalContinuation = roadNaturalContinuation -- for debugging

-- scriptai
M.startRecording = startRecording
M.stopRecording = stopRecording
M.startFollowing = startFollowing
M.stopFollowing = scriptStop
M.scriptStop = scriptStop
M.scriptState = scriptState
M.setScriptDebugMode = setScriptDebugMode
M.setTractionModel = setTractionModel
M.setSpeedProfileMode = setSpeedProfileMode

return M
