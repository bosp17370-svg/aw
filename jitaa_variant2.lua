local antiAimTab = gui.Reference("Ragebot", "Anti-Aim")

local function seedRandom()
    local seed = common.Time()

    math.randomseed(seed)

    for _ = 1, 32 do
        math.random()
    end
end

seedRandom()

local refs = {
    yawOffset = gui.Reference("Ragebot", "Anti-Aim", "Yaw Offset"),
    pitch = gui.Reference("Ragebot", "Anti-Aim", "Pitch"),
    pitchAngle = gui.Reference("Ragebot", "Anti-Aim", "Pitch Angle"),
    yawBase = gui.Reference("Ragebot", "Anti-Aim", "Yaw Base"),
    jitter = gui.Reference("Ragebot", "Anti-Aim", "Jitter"),
    mouseOverride = gui.Reference("Ragebot", "Anti-Aim", "Mouse Override")
}

local yawMode = gui.Combobox(
    antiAimTab,
    "c_yaw_mode",
    "Yaw Base",
    "At Target",
    "Local View"
)

local manualYawLeft = gui.Keybox(antiAimTab, "c_target_yaw_manual_left", "Manual Left", 0);
local manualYawRight = gui.Keybox(antiAimTab, "c_target_yaw_manual_right", "Manual Right", 0);
local manualYawForward = gui.Keybox(antiAimTab, "c_target_yaw_manual_forward", "Manual Forward", 0);
local manualFix = gui.Checkbox(antiAimTab, "c_target_yaw_manual_fix", "Check if you have unbinding problem", false);

local manualYawLeft_val = manualYawLeft:GetValue();
local manualYawRight_val = manualYawRight:GetValue();
local manualYawForward_val = manualYawForward:GetValue();

local yawOffset = gui.Slider(antiAimTab, "c_target_yaw_offset", "Yaw Offset", 0, -180, 180, 1)

local jitterMin = gui.Slider(antiAimTab, "c_yaw_jitter_min", "Min Yaw Jitter", 60, 45, 90, 1)
local jitterMax = gui.Slider(antiAimTab, "c_yaw_jitter_max", "Max Yaw Jitter", 80, 45, 90, 1)

local pathMultiplierMin = gui.Slider(
    antiAimTab,
    "c_path_multiplier_min",
    "Min Path Length Jitter Min",
    60,
    30,
    90,
    1
)

local pathMultiplierMax = gui.Slider(
    antiAimTab,
    "c_path_multiplier_max",
    "Min Path Length Jitter Max",
    80,
    30,
    90,
    1
)

local fractionalJitter = gui.Checkbox(antiAimTab, "c_pitch_mode_frac_jit", "Fractional Jitter", true);

local pitchMin = gui.Slider(antiAimTab, "c_pitch_min", "Min Pitch", -25, -89, -25, 1)
local pitchMax = gui.Slider(antiAimTab, "c_pitch_max", "Max Pitch", -42, -89, -25, 1)

local pitchHoldOn = gui.Checkbox(
    antiAimTab,
    "c_pitch_hold",
    "Force Lowest Downward Pitch",
    false
)

local maxDownwardPitchDifferenceOnManual = gui.Checkbox(antiAimTab, "c_pitch_hold_manuals",
    "Force Lowest Downward Pitch On Manuals", false);

local maxDownwardPitchDifference = gui.Slider(
    antiAimTab,
    "c_max_downward_pitch_difference",
    "Max Downward Pitch Difference",
    8,
    5,
    25,
    1
)

refs.pitch:SetDisabled(true)
refs.pitchAngle:SetDisabled(true)
refs.yawOffset:SetDisabled(true)
refs.yawBase:SetDisabled(true)
refs.jitter:SetDisabled(true)
refs.mouseOverride:SetDisabled(true)

local yaw = 0
local pitch = -25

local tick = 0
local hitTick = 0
local safetyTick = 0

local override = 0

local currentPoint = {
    yaw = 0,
    pitch = -25
}

local previousPoint = nil
local lastPath = nil

local blockedPaths = {}
local pathMemory = {}
local pendingFixes = {}

local PATH_BLOCK_TIME = 50
local MAX_TARGET_ATTEMPTS = 512
local PATH_MEMORY_TIME = 20000
local PATH_REPEAT_WEIGHT = 250

local function normalizeYaw(value)
    while value > 180 do
        value = value - 360
    end

    while value < -180 do
        value = value + 360
    end

    return value
end

local function roundValue(value)
    return math.floor(value + 0.5)
end

local function pointKey(point)
    local pointYaw = roundValue(normalizeYaw(point.yaw))
    local pointPitch = roundValue(point.pitch)

    return tostring(pointYaw) .. ":" .. tostring(pointPitch)
end

local function pathKey(fromPoint, toPoint)
    return pointKey(fromPoint) .. ">" .. pointKey(toPoint)
end

local function shortestYawDelta(fromYaw, toYaw)
    return normalizeYaw(toYaw - fromYaw)
end

local function pathDistance(fromPoint, toPoint)
    local yawDelta = shortestYawDelta(fromPoint.yaw, toPoint.yaw)
    local pitchDelta = toPoint.pitch - fromPoint.pitch

    return math.sqrt(yawDelta * yawDelta + pitchDelta * pitchDelta)
end

local function handle_toggle(key, stateId)
    if key ~= 0 and input.IsButtonPressed(key) then
        override = override == stateId and 0 or stateId
    end
end

local function applyYawOffset(value)
    local offset = yawOffset:GetValue()

    if override == 1 then
        offset = -90
    elseif override == 2 then
        offset = 90
    elseif override == 3 then
        offset = 180
    end

    return normalizeYaw(value + offset)
end

local function getJitterBounds()
    local minValue = math.floor(jitterMin:GetValue())
    local maxValue = math.floor(jitterMax:GetValue())

    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return minValue, maxValue
end

local function getPitchBounds()
    local minValue = math.floor(pitchMin:GetValue())
    local maxValue = math.floor(pitchMax:GetValue())

    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return minValue, maxValue
end

local function getLowestDownwardPitchBounds()
    local upperPitch = math.floor(pitchMin:GetValue())
    local lowerLimit = math.floor(pitchMax:GetValue())
    local maxDifference = maxDownwardPitchDifference:GetValue()

    local forcedMax = upperPitch
    local forcedMin = upperPitch - maxDifference

    if forcedMin < lowerLimit then
        forcedMin = lowerLimit
    end

    if forcedMin > forcedMax then
        forcedMin, forcedMax = forcedMax, forcedMin
    end

    return forcedMin, forcedMax
end

local function getRandomPitch()
    if pitchHoldOn:GetValue() or (maxDownwardPitchDifferenceOnManual:GetValue() and override ~= 0) then
        local forcedMin, forcedMax = getLowestDownwardPitchBounds()

        return math.random(forcedMin, forcedMax)
    end

    local pitchLow, pitchHigh = getPitchBounds()

    return math.random(pitchLow, pitchHigh)
end

local function getMinPathDistance()
    local minValue = math.floor(pathMultiplierMin:GetValue())
    local maxValue = math.floor(pathMultiplierMax:GetValue())

    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return math.random(minValue, maxValue)
end

local function isPathBlocked(fromPoint, toPoint)
    return blockedPaths[pathKey(fromPoint, toPoint)] ~= nil
end

local function blockPath(fromPoint, toPoint, duration)
    duration = duration or PATH_BLOCK_TIME

    blockedPaths[pathKey(fromPoint, toPoint)] = tick + duration
end

local function updateBlockedPaths()
    for key, expiresAt in pairs(blockedPaths) do
        if tick >= expiresAt then
            blockedPaths[key] = nil
        end
    end
end

local function rememberSoftPath(fromPoint, toPoint)
    local key = pathKey(fromPoint, toPoint)
    local data = pathMemory[key]

    if data == nil then
        pathMemory[key] = {
            lastSeen = tick,
            count = 1
        }

        return
    end

    data.lastSeen = tick
    data.count = data.count + 1
end

local function clearOldPathMemory()
    for key, data in pairs(pathMemory) do
        if tick - data.lastSeen > PATH_MEMORY_TIME then
            pathMemory[key] = nil
        end
    end
end

local function getPathMemoryScore(fromPoint, toPoint)
    local key = pathKey(fromPoint, toPoint)
    local data = pathMemory[key]

    if data == nil then
        return math.random(0, 1000) / 1000
    end

    local age = tick - data.lastSeen
    local recencyPenalty = math.max(0, PATH_MEMORY_TIME - age)
    local repeatPenalty = data.count * PATH_REPEAT_WEIGHT
    local noise = math.random(0, 1000) / 1000

    return recencyPenalty + repeatPenalty + noise
end

local function getRandomPoint()
    local yawMin, yawMax = getJitterBounds()

    local yawSide = math.random(0, 1) == 1 and 1 or -1
    local rawYaw = math.random(yawMin, yawMax) * yawSide

    return {
        yaw = applyYawOffset(rawYaw),
        pitch = getRandomPitch()
    }
end

local function pickNextPoint()
    local minDistance = getMinPathDistance()
    local bestPoint = nil
    local bestScore = nil

    for _ = 1, MAX_TARGET_ATTEMPTS do
        local candidate = getRandomPoint()
        local distance = pathDistance(currentPoint, candidate)

        if distance >= minDistance and not isPathBlocked(currentPoint, candidate) then
            local score = getPathMemoryScore(currentPoint, candidate)

            if bestScore == nil or score < bestScore then
                bestScore = score
                bestPoint = candidate
            end
        end
    end

    if bestPoint ~= nil then
        return bestPoint
    end

    bestPoint = nil
    bestScore = nil

    for _ = 1, MAX_TARGET_ATTEMPTS do
        local candidate = getRandomPoint()

        if not isPathBlocked(currentPoint, candidate) then
            local score = getPathMemoryScore(currentPoint, candidate)

            if bestScore == nil or score < bestScore then
                bestScore = score
                bestPoint = candidate
            end
        end
    end

    if bestPoint ~= nil then
        return bestPoint
    end

    return getRandomPoint()
end

local function updateAimPath()
    tick = tick + 1

    updateBlockedPaths()
    clearOldPathMemory()

    previousPoint = {
        yaw = currentPoint.yaw,
        pitch = currentPoint.pitch
    }

    local nextPoint = pickNextPoint()

    lastPath = {
        from = {
            yaw = previousPoint.yaw,
            pitch = previousPoint.pitch
        },
        to = {
            yaw = nextPoint.yaw,
            pitch = nextPoint.pitch
        }
    }

    rememberSoftPath(lastPath.from, lastPath.to)

    currentPoint.yaw = nextPoint.yaw
    currentPoint.pitch = nextPoint.pitch

    yaw = roundValue(normalizeYaw(currentPoint.yaw))
    pitch = roundValue(currentPoint.pitch)

    refs.pitchAngle:SetValue(4)

    if yawMode:GetValue() == 0 then
        refs.yawBase:SetValue(1)
    else
        refs.yawBase:SetValue(2)
    end

    return yaw, pitch
end

local function onHit()
    hitTick = hitTick + 1

    if lastPath ~= nil then
        blockPath(lastPath.from, lastPath.to, PATH_BLOCK_TIME)
    end
end

local function scheduleFix(id, isBroken, fix, delay)
    delay = delay or 20

    if not isBroken() then
        pendingFixes[id] = nil
        return
    end

    local fixData = pendingFixes[id]

    if fixData == nil then
        pendingFixes[id] = {
            startedAt = safetyTick,
            isBroken = isBroken,
            fix = fix,
            delay = delay
        }

        return
    end

    fixData.isBroken = isBroken
    fixData.fix = fix
    fixData.delay = delay
end

local function updatePendingFixes()
    safetyTick = safetyTick + 1

    for id, fixData in pairs(pendingFixes) do
        if not fixData.isBroken() then
            pendingFixes[id] = nil
        elseif safetyTick - fixData.startedAt >= fixData.delay then
            fixData.fix()
            pendingFixes[id] = nil
        end
    end
end

local function swapValues(firstRef, secondRef)
    local firstValue = firstRef:GetValue()
    local secondValue = secondRef:GetValue()

    firstRef:SetValue(secondValue)
    secondRef:SetValue(firstValue)
end

local function runSafetyChecks()
    scheduleFix(
        "invalid_jitter_range",
        function()
            return jitterMax:GetValue() < jitterMin:GetValue()
        end,
        function()
            swapValues(jitterMin, jitterMax)
        end,
        100
    )

    scheduleFix(
        "invalid_path_length_range",
        function()
            return pathMultiplierMax:GetValue() < pathMultiplierMin:GetValue()
        end,
        function()
            swapValues(pathMultiplierMin, pathMultiplierMax)
        end,
        100
    )

    scheduleFix(
        "invalid_pitch_range",
        function()
            return pitchMax:GetValue() > pitchMin:GetValue()
        end,
        function()
            swapValues(pitchMin, pitchMax)
        end,
        100
    )

    scheduleFix(
        "unsafe_pitch_gap",
        function()
            return math.abs(pitchMax:GetValue()) - math.abs(pitchMin:GetValue()) < maxDownwardPitchDifference:GetValue()
        end,
        function()
            local fixedValue = -(math.abs(pitchMin:GetValue()) + maxDownwardPitchDifference:GetValue())

            if fixedValue < -89 then
                fixedValue = -89
            end

            pitchMax:SetValue(fixedValue)
        end,
        100
    )
end

callbacks.Register("Draw", function()
    if manualYawLeft_val ~= manualYawLeft:GetValue() and (manualYawLeft:GetValue() ~= 0 or manualFix:GetValue()) then
        manualYawLeft_val = manualYawLeft:GetValue();
    elseif manualYawLeft:GetValue() == 0 and not manualFix:GetValue() then
        manualYawLeft:SetValue(manualYawLeft_val)
    end
    if manualYawRight_val ~= manualYawRight:GetValue() and (manualYawRight:GetValue() ~= 0 or manualFix:GetValue()) then
        manualYawRight_val = manualYawRight:GetValue();
    elseif manualYawRight:GetValue() == 0 and not manualFix:GetValue() then
        manualYawRight:SetValue(manualYawRight_val)
    end
    if manualYawForward_val ~= manualYawForward:GetValue() and (manualYawForward:GetValue() ~= 0 or manualFix:GetValue()) then
        manualYawForward_val = manualYawForward:GetValue();
    elseif manualYawLeft:GetValue() == 0 and not manualFix:GetValue() then
        manualYawForward:SetValue(manualYawForward_val)
    end

    if manualYawLeft_val == 0 and override == 1 then override = 0 end
    if manualYawRight_val == 0 and override == 2 then override = 0 end
    if manualYawForward_val == 0 and override == 3 then override = 0 end

    handle_toggle(manualYawLeft_val, 1);
    handle_toggle(manualYawRight_val, 2);
    handle_toggle(manualYawForward_val, 3);
end)

callbacks.Register("FireGameEvent", function(event)
    if event:GetName() ~= "player_hurt" then
        return
    end

    local localPlayer = entities.GetLocalPlayer()

    if not localPlayer or not localPlayer:IsAlive() then
        return
    end

    local attackerIndex = bit.band(event:GetInt("attacker_pawn"), 0x7FFF)

    if attackerIndex == client.GetLocalPlayerIndex() then
        onHit()
    end
end)

local function getFractionalPitch(basePitch)
    local offset = math.random(1, 999) / 1000

    return basePitch - offset
end

callbacks.Register("PreMove", function(userCmd)
    if not userCmd then
        return
    end

    runSafetyChecks()
    updatePendingFixes()

    refs.jitter:SetValue(false)
    refs.mouseOverride:SetValue(false)

    local localPlayer = entities.GetLocalPlayer()

    if not localPlayer or not localPlayer:IsAlive() then
        return
    end

    updateAimPath()

    refs.pitch:SetValue(pitch)
    refs.yawOffset:SetValue(yaw)

    if fractionalJitter:GetValue() then
        local nang = userCmd:GetViewAngles()
        nang.x = getFractionalPitch(nang.x)

        userCmd:SetViewAngles(nang)
    end
end)

callbacks.Register("Unload", function()
    refs.pitch:SetDisabled(false)
    refs.pitchAngle:SetDisabled(false)
    refs.yawOffset:SetDisabled(false)
    refs.yawBase:SetDisabled(false)
    refs.jitter:SetDisabled(false)
    refs.mouseOverride:SetDisabled(false)
end)
