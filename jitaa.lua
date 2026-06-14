local antiAimTab = gui.Reference("Ragebot", "Anti-Aim")

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

local spinSpeed = gui.Slider(antiAimTab, "c_spin_speed", "Spin Speed", 5, 3, 50, 1)

local manualYawLeft = gui.Keybox(antiAimTab, "c_target_yaw_manual_left", "Manual Left", 0);
local manualYawRight = gui.Keybox(antiAimTab, "c_target_yaw_manual_right", "Manual Right", 0);
local manualYawForward = gui.Keybox(antiAimTab, "c_target_yaw_manual_forward", "Manual Forward", 0);
local manualFix = gui.Checkbox(antiAimTab, "c_target_yaw_manual_fix", "Check if you have unbinding problem", false);

local manualYawLeft_val = manualYawLeft:GetValue();
local manualYawRight_val = manualYawRight:GetValue();
local manualYawForward_val = manualYawForward:GetValue();

local yawOffset = gui.Slider(antiAimTab, "c_target_yaw_offset", "Yaw Offset", 0, -180, 180, 1)

local jitterMin = gui.Slider(antiAimTab, "c_yaw_jitter_min", "Min Yaw Jitter", 60, 45, 90, 1)
local jitterMax = gui.Slider(antiAimTab, "c_yaw_jitter_max", "Max Yaw Jitter", 75, 45, 90, 1)

local pitchMode = gui.Combobox(
    antiAimTab,
    "c_pitch_mode",
    "Pitch Mode",
    "Incremental",
    "Jitter Exclusive"
)

local fractionalJitter = gui.Checkbox(antiAimTab, "c_pitch_mode_frac_jit", "Fractional Jitter", true);

local pitchHoldOn = gui.Checkbox(antiAimTab, "c_pitch_hold", "Force Lowest Downward Pitch", false);
local maxDownwardPitchDifferenceOnManual = gui.Checkbox(antiAimTab, "c_pitch_hold_manuals",
    "Force Lowest Downward Pitch On Manuals", false);

local pitchMin = gui.Slider(antiAimTab, "c_pitch_min", "Min Pitch", -25, -89, -25, 1)
local pitchMax = gui.Slider(antiAimTab, "c_pitch_max", "Max Pitch", -55, -89, -25, 1)

local fakeAngles = gui.Checkbox(antiAimTab, "c_pitch_fakes", "Use Fake Pitch", false);

refs.pitch:SetDisabled(true)
refs.pitchAngle:SetDisabled(true)
refs.yawOffset:SetDisabled(true)
refs.yawBase:SetDisabled(true)
refs.jitter:SetDisabled(true)
refs.mouseOverride:SetDisabled(true)

local forcedPitchBlocks = {}
local FORCED_PITCH_BLOCK_TIME = 10

local yaw = 0
local pitch = -25
local spinYaw = 0
local spinDirection = 1
local lastYawSide = nil

local tick = 0
local hitTick = 0
local safetyTick = 0

local blockedYaws = {}
local timedYawBlocks = {}
local yawHistory = {}
local seenPatterns = {}

local timedPitchBlocks = {}
local pitchHistory = {}
local seenPitchPatterns = {}

local pendingFixes = {}

local YAW_BLOCK_TIME = 5
local PATTERN_COOLDOWN = 10
local MAX_HISTORY = 32
local PITCH_BLOCK_TIME = 5
local PITCH_BLOCK_RADIUS = 1

local override = 0;

local function normalizeYaw(value)
    while value > 180 do
        value = value - 360
    end

    while value < -180 do
        value = value + 360
    end

    return value
end

local function handle_toggle(key, state_id)
    local key = key;
    if key ~= 0 and input.IsButtonPressed(key) then
        override = (override == state_id) and 0 or state_id;
    end;
end

local function applyYawOffset(value)
    local yawOffset = yawOffset:GetValue()
    if override == 1 then yawOffset = -90 end
    if override == 2 then yawOffset = 90 end
    if override == 3 then yawOffset = 180 end
    return normalizeYaw(value + yawOffset)
end

local function yawKey(value)
    return tostring(math.floor(value + 0.5))
end

local function patternKey(a, b, c)
    return tostring(a) .. "|" .. tostring(b) .. "|" .. tostring(c)
end

local YAW_BLOCK_RADIUS = 4

local function blockYaw(value)
    local center = math.floor(value + 0.5)

    for offset = -YAW_BLOCK_RADIUS, YAW_BLOCK_RADIUS do
        local blockedYaw = normalizeYaw(center + offset)
        blockedYaws[yawKey(blockedYaw)] = true
    end
end

local function unblockYaw(value)
    local center = math.floor(value + 0.5)

    for offset = -YAW_BLOCK_RADIUS, YAW_BLOCK_RADIUS do
        local blockedYaw = normalizeYaw(center + offset)
        blockedYaws[yawKey(blockedYaw)] = nil
    end
end

local function blockYawTemporarily(value, duration)
    duration = duration or YAW_BLOCK_TIME

    local center = math.floor(value + 0.5)

    for offset = -YAW_BLOCK_RADIUS, YAW_BLOCK_RADIUS do
        local blockedYaw = normalizeYaw(center + offset)

        timedYawBlocks[yawKey(blockedYaw)] = {
            yaw = blockedYaw,
            expiresAt = hitTick + duration
        }
    end
end

local function isYawBlocked(value)
    local key = yawKey(value)

    return blockedYaws[key] == true or timedYawBlocks[key] ~= nil
end

local function updateYawBlocks()
    for key, block in pairs(timedYawBlocks) do
        if hitTick >= block.expiresAt then
            timedYawBlocks[key] = nil
        end
    end
end

local function pitchKey(value)
    return tostring(math.floor(value * 10 + 0.5) / 10)
end

local function blockForcedPitch(value, duration)
    duration = duration or FORCED_PITCH_BLOCK_TIME

    forcedPitchBlocks[pitchKey(value)] = {
        pitch = value,
        expiresAt = hitTick + duration
    }
end

local function isForcedPitchBlocked(value)
    return forcedPitchBlocks[pitchKey(value)] ~= nil
end

local function updateForcedPitchBlocks()
    for key, block in pairs(forcedPitchBlocks) do
        if hitTick >= block.expiresAt then
            forcedPitchBlocks[key] = nil
        end
    end
end

local function blockPitchTemporarily(value, duration)
    duration = duration or PITCH_BLOCK_TIME

    local center = math.floor(value + 0.5)

    for offset = -PITCH_BLOCK_RADIUS, PITCH_BLOCK_RADIUS do
        local blockedPitch = center + offset

        timedPitchBlocks[pitchKey(blockedPitch)] = {
            pitch = blockedPitch,
            expiresAt = hitTick + duration
        }
    end
end

local function isPitchBlocked(value)
    return timedPitchBlocks[pitchKey(value)] ~= nil
end

local function updatePitchBlocks()
    for key, block in pairs(timedPitchBlocks) do
        if hitTick >= block.expiresAt then
            timedPitchBlocks[key] = nil
        end
    end
end

local function getPitchBounds()
    local minValue = math.floor(pitchMin:GetValue())
    local maxValue = math.floor(pitchMax:GetValue())

    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return minValue, maxValue
end

local function getLowestAvailablePitch()
    local minValue, maxValue = getPitchBounds()

    for value = maxValue, minValue, -1 do
        if not isForcedPitchBlocked(value) then
            return value
        end
    end

    return maxValue
end

local function getRandomPitch()
    local minValue, maxValue = getPitchBounds()

    local minScaled = minValue * 10
    local maxScaled = maxValue * 10

    return math.random(minScaled, maxScaled) / 10
end

local function getFractionalPitch(basePitch)
    local offset = math.random(1, 999) / 1000

    return basePitch - offset
end

local function normalizePitchForPattern(value)
    return math.floor(value * 10 + 0.5) / 10
end

local function isPitchPatternBlocked(candidatePitch)
    candidatePitch = normalizePitchForPattern(candidatePitch)

    local count = #pitchHistory

    if count < 2 then
        return false
    end

    local key = patternKey(
        pitchHistory[count - 1],
        pitchHistory[count],
        candidatePitch
    )

    local lastSeen = seenPitchPatterns[key]

    return lastSeen ~= nil and (tick + 1) - lastSeen <= PATTERN_COOLDOWN
end

local function rememberPitch(value)
    value = normalizePitchForPattern(value)

    table.insert(pitchHistory, value)

    while #pitchHistory > MAX_HISTORY do
        table.remove(pitchHistory, 1)
    end

    if #pitchHistory < 3 then
        return
    end

    local count = #pitchHistory
    local key = patternKey(
        pitchHistory[count - 2],
        pitchHistory[count - 1],
        pitchHistory[count]
    )

    seenPitchPatterns[key] = tick
end

local function generateJitterPitch()
    local candidatePitch = 0

    for _ = 1, 64 do
        candidatePitch = getRandomPitch()

        if not isPitchBlocked(candidatePitch) and not isPitchPatternBlocked(candidatePitch) then
            return candidatePitch
        end
    end

    local minValue, maxValue = getPitchBounds()

    for value = minValue, maxValue do
        if not isPitchBlocked(value) then
            return value
        end
    end

    return minValue
end

local function getJitterBounds()
    local minValue = math.floor(jitterMin:GetValue())
    local maxValue = math.floor(jitterMax:GetValue())

    if minValue > maxValue then
        minValue, maxValue = maxValue, minValue
    end

    return minValue, maxValue
end

local function getRandomJitter()
    local minValue, maxValue = getJitterBounds()

    return math.random(minValue, maxValue)
end

local function isPatternBlocked(candidateYaw)
    local count = #yawHistory

    if count < 2 then
        return false
    end

    local key = patternKey(yawHistory[count - 1], yawHistory[count], candidateYaw)
    local lastSeen = seenPatterns[key]

    return lastSeen ~= nil and (tick + 1) - lastSeen <= PATTERN_COOLDOWN
end

local function rememberYaw(value)
    tick = tick + 1

    table.insert(yawHistory, value)

    while #yawHistory > MAX_HISTORY do
        table.remove(yawHistory, 1)
    end

    if #yawHistory < 3 then
        return
    end

    local count = #yawHistory
    local key = patternKey(yawHistory[count - 2], yawHistory[count - 1], yawHistory[count])

    seenPatterns[key] = tick
end

local function getNextYawSide()
    return lastYawSide == nil and 1 or -lastYawSide
end

local function generateJitterYaw()
    local side = getNextYawSide()
    local rawYaw = 0
    local finalYaw = 0

    for _ = 1, 64 do
        rawYaw = getRandomJitter() * side
        finalYaw = applyYawOffset(rawYaw)

        if not isYawBlocked(finalYaw) and not isPatternBlocked(finalYaw) then
            return finalYaw, side
        end
    end

    local minValue, maxValue = getJitterBounds()

    for value = minValue, maxValue do
        rawYaw = value * side
        finalYaw = applyYawOffset(rawYaw)

        if not isYawBlocked(finalYaw) then
            return finalYaw, side
        end
    end

    return applyYawOffset(minValue * side), side
end

local function updateSpinYaw()
    local speed = spinSpeed:GetValue() * spinDirection

    for multiplier = 1, 8 do
        local rawYaw = normalizeYaw(spinYaw + speed * multiplier)
        local finalYaw = applyYawOffset(rawYaw)

        if not isYawBlocked(finalYaw) then
            spinYaw = rawYaw
            return finalYaw
        end
    end

    spinYaw = normalizeYaw(spinYaw + speed * 2)

    return applyYawOffset(spinYaw)
end

local function updateYaw()
    refs.pitchAngle:SetValue(4)

    if yawMode:GetValue() == 2 then
        refs.yawBase:SetValue(1)

        yaw = updateSpinYaw()

        return yaw
    end

    refs.yawBase:SetValue(yawMode:GetValue() + 1)

    local selectedYawSide

    yaw, selectedYawSide = generateJitterYaw()

    rememberYaw(yaw)

    lastYawSide = selectedYawSide

    return yaw
end

local function fixPitch()
    local minValue, maxValue = getPitchBounds()

    if pitch < minValue or pitch > maxValue then
        pitch = pitchMin:GetValue()
    end
end

local function updatePitch()
    if not fakeAngles:GetValue() and (pitchHoldOn:GetValue() or (maxDownwardPitchDifferenceOnManual:GetValue() and override ~= 0)) then
        pitch = getLowestAvailablePitch()
        return pitch
    end

    if pitchMode:GetValue() == 1 then
        pitch = generateJitterPitch()
        rememberPitch(pitch)
        return pitch
    end

    fixPitch()

    return pitch
end

local function onHit()
    hitTick = hitTick + 1
    spinDirection = -spinDirection

    updateYawBlocks()
    updatePitchBlocks()
    updateForcedPitchBlocks()

    blockYawTemporarily(yaw, YAW_BLOCK_TIME)

    if not fakeAngles:GetValue() and (pitchHoldOn:GetValue() or (maxDownwardPitchDifferenceOnManual:GetValue() and override ~= 0)) then
        blockForcedPitch(pitch, FORCED_PITCH_BLOCK_TIME)
    end

    if pitchMode:GetValue() == 1 then
        blockPitchTemporarily(pitch, PITCH_BLOCK_TIME)
        return
    end

    fixPitch()

    pitch = pitch - 1
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
            return math.abs(pitchMax:GetValue()) - math.abs(pitchMin:GetValue()) < 5
        end,
        function()
            pitchMax:SetValue(-(math.abs(pitchMin:GetValue()) + 5))
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

    fractionalJitter:SetInvisible(pitchMode:GetValue() == 1)

    local isSpinMode = yawMode:GetValue() == 2

    spinSpeed:SetInvisible(not isSpinMode)
    jitterMin:SetInvisible(isSpinMode)
    jitterMax:SetInvisible(isSpinMode)
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

    updateYaw()
    updatePitch()

    refs.pitch:SetValue(pitch)
    refs.yawOffset:SetValue(yaw)

    if pitchMode:GetValue() == 1 or (pitchMode:GetValue() == 0 and fractionalJitter:GetValue()) then
        local nang = userCmd:GetViewAngles()
        if fakeAngles:GetValue() then
            nang.x = nang.x - 250
        end

        if pitchMode:GetValue() == 1 then
            nang.x = pitch
        else
            nang.x = getFractionalPitch(nang.x)
        end

        userCmd:SetViewAngles(nang)
    end
end)

callbacks.Register("CreateMove", function(userCmd)
    if not userCmd then
        return
    end

    local localPlayer = entities.GetLocalPlayer()

    if not localPlayer or not localPlayer:IsAlive() then
        return
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
