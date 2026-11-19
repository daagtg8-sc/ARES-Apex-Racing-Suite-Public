--[[
    ARES | Apex Racing Suite
    Version: 1.04 HYBRID REBUILD
    Platform focus: Roblox mobile / Android

    Baseline concepts retained from the user's v0.85 source:
      - Track Layout centerline as the primary geometry source
      - Native RacingLine as a guarded fallback only
      - RiderSeat detection
      - Pure Pursuit-style target steering
      - Predictive corner braking
      - A / D / S keyboard bridge via VirtualInputManager

    Changes in this build:
      - Lookahead remains adjustable from 1..100 generated line samples (default 5)
      - Fractional segment progress makes the target move continuously between points
      - Tighter, direction-aware local progress window reduces track-section jumps
      - Corner scanner selects the first sustained bend, not the smallest radius in the horizon
      - Corner entry distance / apex / exit telemetry and early curvature feed-forward
      - Faster steering smoothing and shorter A/D pulse / reversal delays
      - SETUP line-correction slider is now connected to the steering equation
      - BRAIN shows corner phase, direction, entry distance, feed-forward and yaw telemetry
      - Independent Auto Steer / Brake / Throttle and combined Autoplay remain available
      - AutoThrottle still assumes W is the forward/throttle key; verify in-game
      - Mobile-first RIDE / BRAIN / SETUP / HEALTH GUI
      - Key release retries and explicit input acknowledgement disclaimer

    IMPORTANT:
      VirtualInputManager is executor/runtime-dependent. A successful pcall only
      means the call did not throw; it does NOT prove Moto Legends accepted input.
      This file has not been tested inside the live Roblox game in this environment. Dynamic Layout loading and input acceptance require in-game validation.
]]

-- ARES 1.04 is a controlled rebuild from the archived 0.93 source plus the
-- 1.03 engineering blueprint. It preserves baseline controllers and adds raw
-- event capture; it does not pretend unknown touch regions are classified.

------------------------------
-- Services and environment --
------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function getExecutorGuiParent()
    if typeof(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then
            return result
        end
    end
    local ok = pcall(function()
        local probe = Instance.new("ScreenGui")
        probe.Name = "MRA_ParentProbe"
        probe.Parent = CoreGui
        probe:Destroy()
    end)
    if ok then
        return CoreGui
    end
    return PlayerGui
end

------------------------------
-- Configuration and state --
------------------------------
local VERSION = "1.04"
local CONFIG = {
    Lookahead = 5,              -- number of native line points ahead
    SteeringSensitivity = 1.00,
    SteeringSmoothing = 0.11,   -- shorter response time to reduce delayed corner entry
    CrossTrackGain = 0.045,     -- active scale; GUI slider now affects the controller
    CornerTurnThresholdDeg = 1.25,
    CornerScanPoints = 160,
    CornerPreviewMin = 80,
    CornerPreviewMax = 360,
    CornerFeedforwardGain = 15.0,
    BrakeAggression = 1.00,
    ThrottleTopSpeedKph = 300,
    UpdateInterval = 0.035,
    LineRefreshInterval = 1.8,
    DynamicLineEnabled = true,
    DynamicLineMaxOffsetMetres = 5.5,
    TrackBoundaryMarginMetres = 3.0,
    DynamicLineApproachMetres = 22.0,
    DynamicLineStrength = 0.72,
    LineRetryInterval = 2.0,
    MaxLineOffset = 100,
    SteeringDeadband = 0.065,
    ReverseConfirmTime = 0.055,
    ReverseNeutralTime = 0.035,
}

local State = {
    alive = true,
    enabled = false,
    autoplay = false,
    autoSteer = false,
    autoBrake = false,
    autoThrottle = false,

    status = "STANDBY",
    lineStatus = "WAITING",
    inputStatus = "NOT CHECKED",
    bikeStatus = "NOT SEATED",
    errorText = "-",

    speed = 0,
    speedKph = 0,
    targetSpeed = 0,
    steer = 0,
    steerRaw = 0,
    brake = 0,
    throttle = 0,
    cornerRadius = math.huge,
    cornerDistance = 0,
    cornerApexDistance = 0,
    cornerExitDistance = 0,
    cornerDirection = "NONE",
    cornerPhase = "STRAIGHT",
    cornerFeedForward = 0,
    cornerLabel = "STRAIGHT",
    offset = 0,
    headingError = 0,
    yawRateDeg = 0,
    segmentAlpha = 0,
    nearestIndex = 0,
    targetIndex = 0,
    lineCount = 0,
    lineMode = "WAITING",
    trackName = "UNKNOWN",
    gripEstimate = 0.85,
    dt = 0,

    inputFault = false,
    lastUiUpdate = 0,
    recorderEnabled = true,
    inputEvents = {},
    activeInputEvents = {},
    inputEventSequence = 0,
}

local heldKeys = {
    A = false,
    D = false,
    S = false,
    W = false,
}

local controller = {
    cachedLine = nil,
    cachedLineAt = 0,
    nextLineAttempt = 0,
    nearestIndex = nil,
    filteredSteer = 0,
    lastStepAt = 0,
    nextStepAt = 0,
    lastBrakeApplied = false,
    throttleApplied = false,

    activeSteerDirection = 0,
    steeringPulseEnds = 0,
    nextSteeringPulse = 0,
    candidateDirection = 0,
    candidateSince = 0,
    neutralUntil = 0,

    ui = nil,
    uiRefs = {},
    connections = {},
}

------------------------------
-- Utility helpers --
------------------------------
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function safeDisconnect(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function addConnection(connection)
    table.insert(controller.connections, connection)
    return connection
end

-- Recorder 2.0 foundation: record raw input transitions without guessing
-- which mobile GUI button a touch represents. Unknown touches stay UNKNOWN.
local function classifyInput(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        local key = input.KeyCode
        if key == Enum.KeyCode.A or key == Enum.KeyCode.Left then return "STEER_LEFT" end
        if key == Enum.KeyCode.D or key == Enum.KeyCode.Right then return "STEER_RIGHT" end
        if key == Enum.KeyCode.W or key == Enum.KeyCode.Up then return "THROTTLE" end
        if key == Enum.KeyCode.S or key == Enum.KeyCode.Down then return "BRAKE" end
    end
    return "UNKNOWN"
end

local function pushInputEvent(eventName, input, reason)
    if not State.recorderEnabled then return end
    State.inputEventSequence += 1
    local pos = input and input.Position
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
    local x, y = 0, 0
    if pos and viewport and viewport.X > 0 and viewport.Y > 0 then
        x, y = pos.X / viewport.X, pos.Y / viewport.Y
    end
    local event = {
        schema = "ARES_EVENT_V2",
        id = State.inputEventSequence,
        timeSec = os.clock(),
        inputId = input and tostring(input) or "SYSTEM",
        event = eventName,
        control = input and classifyInput(input) or "UNKNOWN",
        source = input and (input.UserInputType == Enum.UserInputType.Touch and "TOUCH" or input.UserInputType == Enum.UserInputType.Keyboard and "KEYBOARD" or "OTHER") or "SYSTEM",
        inputType = input and input.UserInputType.Name or "SYSTEM",
        keyCode = input and input.KeyCode.Name or "Unknown",
        screenX = x,
        screenY = y,
        gameProcessed = false,
        speedKmh = State.speedKph or 0,
        progress = State.nearestIndex or 0,
        offsetM = State.offset or 0,
        headingErrorDeg = State.headingError or 0,
        corner = State.cornerLabel or "UNKNOWN",
        phase = State.cornerPhase or "UNKNOWN",
        reason = reason or "",
    }
    table.insert(State.inputEvents, event)
    if #State.inputEvents > 2000 then table.remove(State.inputEvents, 1) end
    return event
end

local function cancelActiveInputs(reason)
    for input, pressEvent in pairs(State.activeInputEvents) do
        local cancelled = pushInputEvent("CANCEL", input, reason or "CANCELLED")
        if cancelled and pressEvent then
            cancelled.holdDurationSec = math.max(0, cancelled.timeSec - (pressEvent.timeSec or cancelled.timeSec))
        end
        State.activeInputEvents[input] = nil
    end
end

local function now()
    return os.clock()
end

local function keyCodeFor(keyName)
    if keyName == "A" then return Enum.KeyCode.A end
    if keyName == "D" then return Enum.KeyCode.D end
    if keyName == "S" then return Enum.KeyCode.S end
    if keyName == "W" then return Enum.KeyCode.W end
    return nil
end

------------------------------
-- Input bridge / safety --
------------------------------
local function sendKey(keyName, isDown)
    local keyCode = keyCodeFor(keyName)
    if not keyCode then
        return false, "INVALID KEY"
    end

    local methodOk, sendMethod = pcall(function()
        return VirtualInputManager and VirtualInputManager.SendKeyEvent
    end)
    if not methodOk or type(sendMethod) ~= "function" then
        State.inputStatus = "VIM UNAVAILABLE"
        State.inputFault = true
        return false, "VIM UNAVAILABLE"
    end

    local ok, err = pcall(function()
        VirtualInputManager:SendKeyEvent(isDown, keyCode, false, game)
    end)

    if ok then
        State.inputStatus = "API CALL OK / GAME ACK UNKNOWN"
        if isDown then
            heldKeys[keyName] = true
        else
            heldKeys[keyName] = false
        end
        return true
    end

    State.inputStatus = "BRIDGE ERROR"
    State.inputFault = true
    State.errorText = tostring(err)
    return false, tostring(err)
end

local function pressKey(keyName)
    if heldKeys[keyName] then
        return true
    end
    return sendKey(keyName, true)
end

local function releaseKey(keyName)
    if not heldKeys[keyName] then
        return true
    end
    -- Do not clear heldKeys unless the release call actually returns without error.
    return sendKey(keyName, false)
end

local function releaseAll()
    local allOkay = true
    for _, keyName in ipairs({ "A", "D", "S", "W" }) do
        if heldKeys[keyName] then
            local ok = releaseKey(keyName)
            if not ok then
                allOkay = false
            end
        end
    end

    controller.activeSteerDirection = 0
    controller.steeringPulseEnds = 0
    controller.nextSteeringPulse = 0
    controller.candidateDirection = 0
    controller.candidateSince = 0
    controller.neutralUntil = now() + CONFIG.ReverseNeutralTime
    controller.filteredSteer = 0
    controller.lastBrakeApplied = false
    controller.throttleApplied = false

    if not allOkay then
        State.inputFault = true
        State.inputStatus = "RELEASE RETRY NEEDED"
    end
    return allOkay
end

local function setBrake(value)
    value = clamp(value or 0, 0, 1)
    State.brake = value

    if value >= 0.10 then
        if not controller.lastBrakeApplied then
            if pressKey("S") then
                controller.lastBrakeApplied = true
            end
        end
    elseif value <= 0.045 then
        if controller.lastBrakeApplied or heldKeys.S then
            releaseKey("S")
            controller.lastBrakeApplied = false
        end
    end
end

local function setThrottle(value)
    value = clamp(value or 0, 0, 1)
    State.throttle = value

    if value >= 0.20 then
        if not controller.throttleApplied then
            if pressKey("W") then
                controller.throttleApplied = true
            end
        end
    elseif value <= 0.08 then
        if controller.throttleApplied or heldKeys.W then
            releaseKey("W")
            controller.throttleApplied = false
        end
    end
end

local function setSteering(value, dt)
    value = clamp(value or 0, -1, 1)
    State.steerRaw = value

    local sensitivity = CONFIG.SteeringSensitivity
    local target = clamp(value * sensitivity, -1, 1)
    local smoothing = clamp(CONFIG.SteeringSmoothing, 0.03, 0.60)
    local alpha = 1 - math.exp(-math.max(dt, 0.001) / smoothing)
    controller.filteredSteer = controller.filteredSteer + (target - controller.filteredSteer) * alpha
    State.steer = controller.filteredSteer

    local magnitude = math.abs(State.steer)
    local wantedDirection = 0
    if magnitude >= CONFIG.SteeringDeadband then
        wantedDirection = State.steer > 0 and 1 or -1
    end

    local t = now()
    if wantedDirection == 0 then
        releaseKey("A")
        releaseKey("D")
        controller.activeSteerDirection = 0
        controller.candidateDirection = 0
        controller.candidateSince = 0
        controller.steeringPulseEnds = 0
        return
    end

    -- Require an opposite command to persist before reversing A <-> D.
    if controller.activeSteerDirection ~= 0 and wantedDirection ~= controller.activeSteerDirection then
        if controller.candidateDirection ~= wantedDirection then
            controller.candidateDirection = wantedDirection
            controller.candidateSince = t
        end
        releaseKey(controller.activeSteerDirection > 0 and "D" or "A")
        controller.steeringPulseEnds = 0
        if t - controller.candidateSince < CONFIG.ReverseConfirmTime then
            return
        end
        controller.activeSteerDirection = 0
        controller.neutralUntil = t + CONFIG.ReverseNeutralTime
        controller.candidateDirection = 0
        controller.candidateSince = 0
        return
    elseif controller.activeSteerDirection == wantedDirection then
        controller.candidateDirection = 0
        controller.candidateSince = 0
    end

    if controller.activeSteerDirection == 0 then
        if t < controller.neutralUntil then
            return
        end
        controller.activeSteerDirection = wantedDirection
        controller.nextSteeringPulse = math.min(controller.nextSteeringPulse, t)
    end

    local keyName = controller.activeSteerDirection > 0 and "D" or "A"
    local oppositeName = controller.activeSteerDirection > 0 and "A" or "D"
    if not releaseKey(oppositeName) then
        -- Never press the opposite direction while a prior key may still be held.
        return
    end

    if controller.steeringPulseEnds > 0 and t >= controller.steeringPulseEnds then
        releaseKey(keyName)
        controller.steeringPulseEnds = 0
    end

    if t >= controller.nextSteeringPulse and not heldKeys[keyName] then
        -- Shorter, more frequent pulses reduce the old 0.2-0.37s steering cycle.
        local pulseDuration = 0.035 + magnitude * 0.085
        local pulseGap = 0.040 + (1 - magnitude) * 0.070
        if pressKey(keyName) then
            controller.steeringPulseEnds = t + pulseDuration
            controller.nextSteeringPulse = t + pulseDuration + pulseGap
        end
    end
end

------------------------------
-- Native Racing Line reader --
------------------------------
local function toWorldPosition(point)
    if typeof(point) == "Vector3" then
        return point
    end
    if typeof(point) == "CFrame" then
        return point.Position
    end
    if typeof(point) == "Instance" and point:IsA("BasePart") then
        return point.Position
    end
    if type(point) == "table" then
        local x = point.x or point.X or point[1]
        local y = point.y or point.Y or point[2]
        local z = point.z or point.Z or point[3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3.new(x, y, z)
        end
    end
    return nil
end

local function getTrackLayout()
    local motoLegends = ReplicatedStorage:FindFirstChild("MotoLegends")
    if not motoLegends then error("MotoLegends folder missing") end

    local configModule = motoLegends:FindFirstChild("Config")
    local tracksFolder = motoLegends:FindFirstChild("Tracks")
    if not configModule or not tracksFolder then
        error("Track Config or Tracks folder missing")
    end

    local gameConfig = require(configModule)
    if type(gameConfig) ~= "table" or type(gameConfig.Track) ~= "string" then
        error("Config.Track unavailable")
    end

    local trackFolder = tracksFolder:FindFirstChild(gameConfig.Track)
    if not trackFolder then error("Track layout folder missing: " .. gameConfig.Track) end
    local layoutModule = trackFolder:FindFirstChild("Layout")
    if not layoutModule then error("Track Layout module missing") end

    local layout = require(layoutModule)
    if type(layout) ~= "table" or type(layout.Points) ~= "table" or #layout.Points < 20 then
        error("Track Layout has invalid centerline points")
    end

    local points = {}
    for i = 1, #layout.Points do
        local v = toWorldPosition(layout.Points[i])
        if not v then error("Invalid track centerline point " .. tostring(i)) end
        points[i] = v
    end

    return {
        points = points,
        n = #points,
        roadWidthMetres = tonumber(layout.RoadWidthMetres) or 12,
        studMetres = tonumber(layout.StudMetres) or 0.28,
        worldScale = tonumber(layout.WorldScale) or 1,
        name = gameConfig.Track,
        layout = layout,
    }
end

local function buildDynamicLine(track, speedStuds, gripEstimate)
    local points, count = track.points, track.n
    local totalLength, cumulative = 0, table.create(count, 0)
    for i = 1, count do
        local ni = (i % count) + 1
        local segmentLength = (points[ni] - points[i]).Magnitude
        totalLength += segmentLength
        if i < count then cumulative[i + 1] = cumulative[i] + segmentLength end
    end
    if totalLength < 100 then error("Track centerline length is implausible") end

    local studMetres = clamp(track.studMetres, 0.05, 2)
    local worldScale = clamp(track.worldScale, 0.1, 5)
    local halfWidth = (track.roadWidthMetres / studMetres) * worldScale * 0.5
    local margin = (CONFIG.TrackBoundaryMarginMetres / studMetres) * worldScale
    local usableHalfWidth = math.max(0, halfWidth - margin)
    if usableHalfWidth < 2 then error("Track width leaves no safe racing corridor") end

    local speedRatio = clamp((speedStuds or 0) / math.max((300 / 3.6) / studMetres, 1), 0, 1)
    local maxOffset = math.min(
        usableHalfWidth * 0.58,
        (CONFIG.DynamicLineMaxOffsetMetres / studMetres) * worldScale
    )
    local gripFactor = clamp(tonumber(gripEstimate) or 0.85, 0.55, 1.15)
    local amplitude = maxOffset * (0.35 + speedRatio * 0.35) * CONFIG.DynamicLineStrength * clamp(0.72 + (gripFactor - 0.55) * 0.50, 0.72, 1.02)

    local function turnAt(i)
        local a = points[(i - 2) % count + 1]
        local b = points[i]
        local c = points[i % count + 1]
        local ab, bc = horizontal(b - a), horizontal(c - b)
        if ab.Magnitude < 0.001 or bc.Magnitude < 0.001 then return 0, math.huge end
        local cross = ab.X * bc.Z - ab.Z * bc.X
        local dot = clamp(ab.Unit:Dot(bc.Unit), -1, 1)
        local angle = math.deg(math.atan2(cross, dot))
        local ca = horizontal(a - c)
        local twiceArea = math.abs(ab.X * bc.Z - ab.Z * bc.X)
        local radius = twiceArea > 1e-5 and (ab.Magnitude * bc.Magnitude * ca.Magnitude) / (2 * twiceArea) or math.huge
        return angle, radius
    end

    local corners, active = {}, nil
    for i = 1, count do
        local angle, radius = turnAt(i)
        local sign = angle >= 0 and 1 or -1
        local qualifies = math.abs(angle) >= 0.28 and radius < 2600
        if qualifies then
            if not active or active.sign ~= sign then
                if active and active.samples >= 3 then corners[#corners + 1] = active end
                active = { sign = sign, first = i, last = i, apex = i, radius = radius, samples = 1 }
            else
                active.last = i
                active.gaps = 0
                active.samples += 1
                if radius < active.radius then active.radius, active.apex = radius, i end
            end
        elseif active then
            active.gaps = (active.gaps or 0) + 1
            if active.gaps > 2 then
                if active.samples >= 3 then corners[#corners + 1] = active end
                active = nil
            end
        end
    end
    if active and active.samples >= 3 then corners[#corners + 1] = active end

    local offsets, weights = table.create(count, 0), table.create(count, 0)
    local approach = (CONFIG.DynamicLineApproachMetres / studMetres) * worldScale
    for _, corner in ipairs(corners) do
        local entryS, apexS, exitS = cumulative[corner.first], cumulative[corner.apex], cumulative[corner.last]
        local apexDistance = apexS - entryS
        if apexDistance < 0 then apexDistance += totalLength end
        local cornerLength = exitS - entryS
        if cornerLength < 0 then cornerLength += totalLength end
        cornerLength = math.max(1, cornerLength)
        for i = 1, count do
            local d = cumulative[i] - entryS
            if d < -totalLength * 0.5 then d += totalLength end
            if d > totalLength * 0.5 then d -= totalLength end
            if d >= -approach and d <= cornerLength + approach then
                local desired
                if d < 0 then
                    desired = -corner.sign * amplitude * clamp((d + approach) / approach, 0, 1)
                elseif d <= apexDistance then
                    local t = clamp(d / math.max(apexDistance, 1), 0, 1)
                    desired = corner.sign * amplitude * (2 * t - 1)
                elseif d <= cornerLength then
                    local exitDistance = math.max(cornerLength - apexDistance, 1)
                    local t = clamp((d - apexDistance) / exitDistance, 0, 1)
                    desired = corner.sign * amplitude * (1 - 2 * t)
                else
                    desired = -corner.sign * amplitude * clamp(1 - (d - cornerLength) / approach, 0, 1)
                end
                local weight = 1
                offsets[i] += desired * weight
                weights[i] += weight
            end
        end
    end

    for i = 1, count do
        if weights[i] > 1 then offsets[i] /= weights[i] end
        offsets[i] = clamp(offsets[i], -usableHalfWidth, usableHalfWidth)
    end
    -- Smooth the lateral plan to avoid abrupt lane changes between adjacent samples.
    for _ = 1, 4 do
        local previous = table.clone(offsets)
        for i = 1, count do
            local before = previous[(i - 2) % count + 1]
            local after = previous[i % count + 1]
            offsets[i] = clamp((before + 2 * previous[i] + after) * 0.25,
                -usableHalfWidth, usableHalfWidth)
        end
    end

    local linePoints = table.create(count)
    for i = 1, count do
        local before = points[(i - 2) % count + 1]
        local after = points[i % count + 1]
        local tangent = horizontal(after - before)
        local right = tangent.Magnitude > 0.001 and tangent.Unit:Cross(Vector3.new(0, 1, 0)) or Vector3.new(1, 0, 0)
        linePoints[i] = points[i] + right * offsets[i]
    end

    local lineLength = 0
    for i = 1, count do
        lineLength += (linePoints[i % count + 1] - linePoints[i]).Magnitude
    end
    return {
        points = linePoints, n = count, totalLength = lineLength,
        averageSpacing = lineLength / count, source = track.layout,
        mode = "DYNAMIC / TRACK LAYOUT", trackName = track.name,
        offsets = offsets, roadWidth = track.roadWidthMetres,
        studMetres = studMetres,
    }
end

local function loadNativeLine()
    local motoLegends = ReplicatedStorage:FindFirstChild("MotoLegends")
    if not motoLegends then error("MotoLegends folder missing") end
    local racingLineModule = motoLegends:FindFirstChild("RacingLine")
    if not racingLineModule then error("RacingLine module missing") end
    local racingLine = require(racingLineModule)
    if type(racingLine) ~= "table" or type(racingLine.Get) ~= "function" then
        error("RacingLine.Get unavailable")
    end
    local result = racingLine.Get()
    if type(result) ~= "table" or type(result.points) ~= "table" then
        error("Native RacingLine returned invalid data")
    end
    local count = math.min(tonumber(result.n) or #result.points, #result.points)
    if count < 8 then error("Native RacingLine has fewer than 8 points") end
    local cleanPoints, totalLength = {}, 0
    for i = 1, count do
        cleanPoints[i] = toWorldPosition(result.points[i])
        if not cleanPoints[i] then error("Invalid native racing line point " .. tostring(i)) end
    end
    for i = 1, count do totalLength += (cleanPoints[i % count + 1] - cleanPoints[i]).Magnitude end
    return { points = cleanPoints, n = count, totalLength = totalLength,
        averageSpacing = totalLength / count, source = result, mode = "NATIVE FALLBACK" }
end

local function loadLine(force, speedStuds, gripEstimate)
    local t = now()
    if not force and controller.cachedLine and t - controller.cachedLineAt < CONFIG.LineRefreshInterval then
        return controller.cachedLine
    end
    if not force and t < controller.nextLineAttempt then return controller.cachedLine end

    controller.nextLineAttempt = t + CONFIG.LineRetryInterval
    State.lineStatus = "PLANNING"
    local ok, lineOrError = pcall(function()
        if CONFIG.DynamicLineEnabled then
            local track = getTrackLayout()
            return buildDynamicLine(track, speedStuds, gripEstimate)
        end
        return loadNativeLine()
    end)

    if not ok or not lineOrError or lineOrError.n < 8 then
        local dynamicError = tostring(lineOrError)
        local fallbackOk, fallbackLine = pcall(loadNativeLine)
        if fallbackOk and fallbackLine and fallbackLine.n >= 8 then
            lineOrError = fallbackLine
            ok = true
            State.errorText = "DYNAMIC LINE FALLBACK: " .. dynamicError
        else
            State.errorText = dynamicError .. " | Native fallback: " .. tostring(fallbackLine)
            ok = false
        end
    end

    if ok and lineOrError and lineOrError.n >= 8 then
        controller.cachedLine = lineOrError
        controller.cachedLineAt = t
        State.lineCount = lineOrError.n
        State.lineMode = lineOrError.mode or "UNKNOWN"
        State.trackName = lineOrError.trackName or "NATIVE"
        State.lineStatus = lineOrError.mode == "NATIVE FALLBACK" and "NATIVE FALLBACK" or "DYNAMIC READY"
        if not controller.nearestIndex then controller.nearestIndex = 1 end
        return lineOrError
    end

    if controller.cachedLine then
        State.lineStatus = "STALE CACHE"
        return controller.cachedLine
    end
    State.lineStatus = "UNAVAILABLE"
    return nil
end

------------------------------
-- Bike / motion reader --
------------------------------
local function getBike()
    local character = LocalPlayer.Character
    if not character then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return nil
    end

    local riderSeat = humanoid.SeatPart
    if not riderSeat or riderSeat.Name ~= "RiderSeat" or not riderSeat:IsA("BasePart") then
        return nil
    end

    local root = riderSeat.AssemblyRootPart or riderSeat
    return {
        character = character,
        humanoid = humanoid,
        seat = riderSeat,
        root = root,
        position = root.Position,
        -- Use the rider seat's forward axis; the assembly root can have different local axes.
        cframe = riderSeat.CFrame,
        velocity = root.AssemblyLinearVelocity,
    }
end

------------------------------
-- Track geometry / tracking --
------------------------------
local function wrapIndex(index, count)
    return ((index - 1) % count) + 1
end

local function segmentProjection(position, a, b)
    local ab = b - a
    local denominator = ab:Dot(ab)
    if denominator < 1e-6 then
        return a, 0
    end
    local alpha = clamp((position - a):Dot(ab) / denominator, 0, 1)
    return a + ab * alpha, alpha
end

local function horizontal(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function projectOnSegment2D(position, a, b)
    local p, aa, bb = horizontal(position), horizontal(a), horizontal(b)
    local ab = bb - aa
    local denominator = ab:Dot(ab)
    if denominator < 1e-6 then return a, 0 end
    local alpha = clamp((p - aa):Dot(ab) / denominator, 0, 1)
    return a:Lerp(b, alpha), alpha
end

local function findNearestPoint(bike, line, dt)
    local points, count = line.points, line.n
    local velocity2D = horizontal(bike.velocity)
    local seatForward = horizontal(bike.cframe.LookVector)
    local travelDirection

    if velocity2D.Magnitude > 8 then
        travelDirection = velocity2D.Unit
        -- When reversing, use the bike's facing direction to keep line progress
        -- attached to the forward racing direction instead of jumping backward.
        if seatForward.Magnitude > 0.001 and travelDirection:Dot(seatForward.Unit) < -0.25 then
            travelDirection = seatForward.Unit
        end
    elseif seatForward.Magnitude > 0.001 then
        travelDirection = seatForward.Unit
    else
        travelDirection = Vector3.new(0, 0, -1)
    end

    local spacing = math.max(tonumber(line.averageSpacing) or 10, 4)
    local predictedTravel = velocity2D.Magnitude * clamp(dt or CONFIG.UpdateInterval, 0.015, 0.18)
    local forwardWindow = clamp(math.ceil(predictedTravel / spacing) + 6, 8, 20)
    local bestIndex, bestScore, bestDistance = 1, math.huge, math.huge
    local bestProjection, bestTangent, bestAlpha = points[1], Vector3.new(0, 0, -1), 0

    local function considerSegment(index, progressOffset)
        local nextIndex = wrapIndex(index + 1, count)
        local a, b = points[index], points[nextIndex]
        local projected, alpha = projectOnSegment2D(bike.position, a, b)
        local tangent = horizontal(b - a)
        if tangent.Magnitude < 0.001 then return end
        tangent = tangent.Unit

        local distance = (horizontal(bike.position) - horizontal(projected)).Magnitude
        local alignment = clamp(tangent:Dot(travelDirection), -1, 1)
        local directionPenalty = (1 - alignment) * 18.0
        local backwardPenalty = progressOffset < 0 and math.abs(progressOffset) * 1.5 or 0
        local forwardPenalty = math.max(progressOffset, 0) * 0.85
        local score = distance + directionPenalty + backwardPenalty + forwardPenalty

        if score < bestScore then
            bestIndex, bestScore, bestDistance = index, score, distance
            bestProjection, bestTangent, bestAlpha = projected, tangent, alpha
        end
    end

    if controller.nearestIndex then
        -- A tight progress window prevents a nearby parallel/overlapping section
        -- from stealing the tracker during corner entry or exit.
        for offset = -2, math.min(forwardWindow, count - 1) do
            considerSegment(wrapIndex(controller.nearestIndex + offset, count), offset)
        end
    else
        for index = 1, count do
            considerSegment(index, 0)
        end
    end

    -- Global reacquisition is reserved for genuine loss of the local corridor.
    if bestDistance > 42 then
        bestScore, bestDistance = math.huge, math.huge
        for index = 1, count do
            considerSegment(index, 0)
        end
    end

    controller.nearestIndex = bestIndex
    local delta = horizontal(bike.position - bestProjection)
    local right = bestTangent:Cross(Vector3.new(0, 1, 0))
    local signedOffset = right.Magnitude > 0.001 and delta:Dot(right.Unit) or 0
    return bestIndex, bestDistance, signedOffset, bestProjection, bestTangent, bestAlpha
end

local function getLookaheadTarget(line, nearestIndex, segmentAlpha)
    local lookahead = math.floor(clamp(CONFIG.Lookahead, 1, 100) + 0.5)
    -- Preserve fractional progress within the current segment. This makes the
    -- target move continuously instead of jumping one whole point at a time.
    local targetProgress = nearestIndex + clamp(segmentAlpha or 0, 0, 1) + lookahead
    local baseIndex = math.floor(targetProgress)
    local alpha = targetProgress - baseIndex
    local targetIndex = wrapIndex(baseIndex, line.n)
    local nextIndex = wrapIndex(targetIndex + 1, line.n)
    local targetPosition = line.points[targetIndex]:Lerp(line.points[nextIndex], alpha)
    return targetPosition, targetIndex, targetProgress
end

local function signedTurnDegrees(a, b, c)
    local incoming = horizontal(b - a)
    local outgoing = horizontal(c - b)
    if incoming.Magnitude < 0.001 or outgoing.Magnitude < 0.001 then
        return 0
    end
    incoming = incoming.Unit
    outgoing = outgoing.Unit
    -- Positive is a right-hand bend when the RacingLine advances along -Z.
    local cross = incoming.X * outgoing.Z - incoming.Z * outgoing.X
    local dot = clamp(incoming:Dot(outgoing), -1, 1)
    return math.deg(math.atan2(cross, dot))
end

local function circleRadius(a, b, c)
    local ab = horizontal(b - a)
    local bc = horizontal(c - b)
    local ca = horizontal(a - c)
    local crossMagnitude = math.abs(ab.X * bc.Z - ab.Z * bc.X)
    if crossMagnitude < 1e-5 then
        return math.huge
    end
    return (ab.Magnitude * bc.Magnitude * ca.Magnitude) / (2 * crossMagnitude)
end

local function getTrackConfig()
    local defaults = {
        Gravity = workspace.Gravity,
        Grip = 0.85,
        MaxLean = math.rad(48),
        StudMetres = 0.28,
        TopSpeedKph = CONFIG.ThrottleTopSpeedKph,
    }

    local ok, result = pcall(function()
        local motoLegends = ReplicatedStorage:FindFirstChild("MotoLegends")
        if not motoLegends then return nil end
        local configModule = motoLegends:FindFirstChild("Config")
        if not configModule then return nil end
        local config = require(configModule)
        if type(config) == "table" then return config end
        return nil
    end)

    if ok and type(result) == "table" then
        local merged = {}
        for key, defaultValue in pairs(defaults) do
            local candidate = result[key]
            merged[key] = type(candidate) == "number" and candidate or defaultValue
        end
        return merged
    end
    return defaults
end

local function scanUpcomingCorner(line, nearestIndex, segmentAlpha)
    local points, count = line.points, line.n
    local maxPoints = math.min(CONFIG.CornerScanPoints, count - 4)
    local travelled = (1 - clamp(segmentAlpha or 0, 0, 1)) *
        (points[wrapIndex(nearestIndex + 1, count)] - points[nearestIndex]).Magnitude
    local active = nil
    local found = nil
    local threshold = CONFIG.CornerTurnThresholdDeg

    local function beginCorner(sign, distance, angle, radius)
        return {
            sign = sign,
            entryDistance = distance,
            apexDistance = distance,
            exitDistance = distance,
            radius = radius,
            samples = 1,
            gaps = 0,
            maxAngle = math.abs(angle),
        }
    end

    local function finishCorner()
        if active and active.samples >= 3 then
            local label = "FAST"
            if active.radius < 145 then
                label = "HAIRPIN"
            elseif active.radius < 230 then
                label = "TIGHT"
            elseif active.radius < 500 then
                label = "MEDIUM"
            end
            active.label = label
            found = active
        end
        active = nil
    end

    for offset = 1, maxPoints do
        local index = wrapIndex(nearestIndex + offset, count)
        local previous = wrapIndex(index - 1, count)
        local nextIndex = wrapIndex(index + 1, count)
        local a, b, c = points[previous], points[index], points[nextIndex]
        local angle = signedTurnDegrees(a, b, c)
        local radius = circleRadius(a, b, c)
        local qualifies = math.abs(angle) >= threshold and radius < 2200
        local sign = angle >= 0 and 1 or -1

        if qualifies then
            if not active then
                active = beginCorner(sign, travelled, angle, radius)
            elseif active.sign ~= sign then
                finishCorner()
                if found then break end
                active = beginCorner(sign, travelled, angle, radius)
            else
                active.samples = active.samples + 1
                active.gaps = 0
                active.exitDistance = travelled
                active.maxAngle = math.max(active.maxAngle, math.abs(angle))
                if radius < active.radius then
                    active.radius = radius
                    active.apexDistance = travelled
                end
            end
        elseif active then
            active.gaps = active.gaps + 1
            if active.gaps > 1 then
                finishCorner()
                if found then break end
            end
        end

        travelled = travelled + (points[nextIndex] - points[index]).Magnitude
    end

    if not found then
        finishCorner()
    end

    if not found then
        return nil
    end
    return found
end

------------------------------
-- Steering / brake / throttle controllers --
------------------------------
local trackConfig = getTrackConfig()

local function calculateSteering(bike, line, nearestIndex, signedOffset, segmentAlpha, corner, dt)
    local targetPosition, targetIndex = getLookaheadTarget(line, nearestIndex, segmentAlpha)
    local forward = horizontal(bike.cframe.LookVector)
    if forward.Magnitude < 0.001 then forward = horizontal(bike.velocity) end
    if forward.Magnitude < 0.001 then
        forward = Vector3.new(0, 0, -1)
    else
        forward = forward.Unit
    end

    local velocity2D = horizontal(bike.velocity)
    if velocity2D.Magnitude > 8 and forward:Dot(velocity2D.Unit) < -0.25 then
        forward = -forward
    end

    local right = Vector3.new(-forward.Z, 0, forward.X)
    local targetDelta = horizontal(targetPosition - bike.position)
    local localX, localZ = targetDelta:Dot(right), targetDelta:Dot(forward)
    local planarDistance = math.max(targetDelta.Magnitude, 1)
    local headingError = math.atan2(localX, localZ)

    local curvature = (2 * math.sin(headingError)) / planarDistance
    local baseSteer = curvature * 13.0

    -- This slider previously existed in SETUP but had no effect on steering.
    local crossTrackScale = clamp(CONFIG.CrossTrackGain / 0.045, 0.35, 2.5)
    local crossTrackCorrection = -math.atan2(signedOffset, math.max(planarDistance, 18)) * 1.15 * crossTrackScale

    -- Feed forward a small amount of the first upcoming bend before the bike
    -- reaches it. Pure Pursuit remains the main feedback controller.
    local cornerFeedForward = 0
    if corner and corner.radius < 2200 and corner.sign then
        local lookaheadPoints = clamp(CONFIG.Lookahead, 1, 100)
        local lookaheadDistance = lookaheadPoints * math.max(line.averageSpacing or 10, 4)
        local speed = horizontal(bike.velocity).Magnitude
        local previewDistance = clamp(math.max(speed * 1.15, lookaheadDistance * 2.0),
            CONFIG.CornerPreviewMin, CONFIG.CornerPreviewMax)
        local anticipation = clamp(1 - (corner.entryDistance / previewDistance), 0, 1)
        local curveFeed = corner.sign * (CONFIG.CornerFeedforwardGain / math.max(corner.radius, 65))
        cornerFeedForward = clamp(curveFeed * anticipation, -0.18, 0.18)
    end

    local steering = clamp((baseSteer + crossTrackCorrection + cornerFeedForward) *
        CONFIG.SteeringSensitivity, -1, 1)

    if localZ < -2 then steering = clamp(steering, -0.35, 0.35) end
    State.headingError = math.deg(headingError)
    State.targetIndex = targetIndex
    State.cornerFeedForward = cornerFeedForward
    return steering
end

local function calculateBrakeAndThrottle(bike, line, nearestIndex, cornerRadius, cornerDistance)
    local config = trackConfig or getTrackConfig()
    local gravity = math.max(tonumber(config.Gravity) or workspace.Gravity, 1)
    local grip = clamp(tonumber(config.Grip) or State.gripEstimate or 0.85, 0.45, 1.35)
    local maxLean = tonumber(config.MaxLean) or math.rad(48)
    if maxLean > math.pi then
        maxLean = math.rad(maxLean)
    end
    maxLean = clamp(maxLean, math.rad(10), math.rad(70))

    local lateralAcceleration = math.max(8, gravity * math.tan(maxLean) * grip * 0.68)
    local studMetres = clamp(tonumber(config.StudMetres) or 0.28, 0.05, 2)
    local topSpeedKph = clamp(tonumber(CONFIG.ThrottleTopSpeedKph) or 300, 50, 300)
    local topSpeedStuds = (topSpeedKph / 3.6) / studMetres
    topSpeedStuds = clamp(topSpeedStuds, 35, 420)

    local speed = Vector3.new(bike.velocity.X, 0, bike.velocity.Z).Magnitude
    local targetSpeed = topSpeedStuds
    local brakeCommand = 0

    if cornerRadius < 500 then
        targetSpeed = math.sqrt(math.max(lateralAcceleration * cornerRadius, 0))
        targetSpeed = math.min(targetSpeed, topSpeedStuds)

        local margin = math.max(36, speed * 0.42)
        local usableDistance = math.max(6, cornerDistance - margin)
        local requiredDeceleration = (speed * speed - targetSpeed * targetSpeed) / (2 * usableDistance)
        local availableDeceleration = math.max(gravity * grip * 0.42, 5)
        local stoppingDistance = 0
        if speed > targetSpeed then
            stoppingDistance = (speed * speed - targetSpeed * targetSpeed) / (2 * availableDeceleration)
        end

        if speed > targetSpeed + 0.8 and cornerDistance <= stoppingDistance + margin then
            brakeCommand = clamp((requiredDeceleration / availableDeceleration) * CONFIG.BrakeAggression, 0.16, 1)
        end
    end

    -- Throttle is intentionally conservative: brake takes priority, then W is
    -- held only while below the predicted speed target.
    local throttleCommand = 0
    if brakeCommand < 0.06 and speed < targetSpeed - 2.0 then
        throttleCommand = 1
    end

    State.targetSpeed = targetSpeed
    return brakeCommand, throttleCommand
end

------------------------------
-- Main controller step --
------------------------------
local function controllerStep(dt)
    local bike = getBike()
    if not bike then
        State.bikeStatus = "WAITING FOR RIDERSEAT"
        State.status = State.enabled and "WAITING FOR BIKE" or "STANDBY"
        State.speed = 0
        State.speedKph = 0
        State.offset = 0
        State.cornerPhase = "STRAIGHT"
        State.cornerDirection = "NONE"
        State.cornerFeedForward = 0
        State.steer = 0
        State.brake = 0
        State.throttle = 0
        releaseAll()
        return
    end

    State.bikeStatus = "RIDERSEAT FOUND"
    -- Use exposed numeric grip only when the game Config provides it; otherwise keep a conservative model.
    State.gripEstimate = clamp(tonumber(trackConfig and trackConfig.Grip) or 0.85, 0.55, 1.15)
    local line = loadLine(false, horizontal(bike.velocity).Magnitude, State.gripEstimate)
    if not line then
        State.status = "WAITING FOR LINE"
        releaseAll()
        return
    end

    local speed = Vector3.new(bike.velocity.X, 0, bike.velocity.Z).Magnitude
    State.speed = speed
    State.speedKph = speed * (tonumber(trackConfig.StudMetres) or 0.28) * 3.6

    local nearestIndex, nearestDistance, signedOffset, projection, tangent, segmentAlpha =
        findNearestPoint(bike, line, dt)
    State.nearestIndex = nearestIndex
    State.offset = signedOffset
    State.segmentAlpha = segmentAlpha or 0
    local angularVelocity = bike.root.AssemblyAngularVelocity
    -- Keep yaw telemetry visible for diagnosis; no uncalibrated yaw term is
    -- injected into steering yet.
    State.yawRateDeg = math.deg(-angularVelocity.Y)

    if nearestDistance > CONFIG.MaxLineOffset then
        State.status = "OFF LINE / REACQUIRE"
        State.steer = 0
        State.brake = 0
        State.throttle = 0
        releaseAll()
        return
    end

    local corner = scanUpcomingCorner(line, nearestIndex, segmentAlpha)
    local cornerRadius = corner and corner.radius or math.huge
    local cornerDistance = corner and corner.entryDistance or 0
    State.cornerRadius = cornerRadius
    State.cornerDistance = cornerDistance
    State.cornerApexDistance = corner and corner.apexDistance or 0
    State.cornerExitDistance = corner and corner.exitDistance or 0
    State.cornerDirection = corner and (corner.sign > 0 and "RIGHT" or "LEFT") or "NONE"
    State.cornerLabel = corner and corner.label or "STRAIGHT"
    if not corner then
        State.cornerPhase = "STRAIGHT"
    elseif corner.entryDistance > 55 then
        State.cornerPhase = "APPROACH"
    elseif corner.apexDistance > 35 then
        State.cornerPhase = "ENTRY"
    elseif corner.exitDistance > 40 then
        State.cornerPhase = "APEX"
    else
        State.cornerPhase = "EXIT"
    end

    local steerCommand = calculateSteering(
        bike, line, nearestIndex, signedOffset, segmentAlpha, corner, dt
    )
    local brakeCommand, throttleCommand = calculateBrakeAndThrottle(
        bike, line, nearestIndex, cornerRadius, cornerDistance
    )

    if State.autoSteer then
        setSteering(steerCommand, dt)
    else
        controller.filteredSteer = 0
        State.steer = 0
        State.steerRaw = 0
        controller.activeSteerDirection = 0
        controller.candidateDirection = 0
        controller.candidateSince = 0
        controller.steeringPulseEnds = 0
        controller.nextSteeringPulse = 0
        releaseKey("A")
        releaseKey("D")
    end

    if State.autoBrake then
        setBrake(brakeCommand)
    else
        setBrake(0)
    end

    if State.autoThrottle then
        if State.autoBrake and brakeCommand >= 0.06 then
            throttleCommand = 0
        end
        setThrottle(throttleCommand)
    else
        setThrottle(0)
    end

    local anyAuto = State.autoSteer or State.autoBrake or State.autoThrottle
    State.enabled = anyAuto
    State.status = anyAuto and "ARMED" or "MONITORING"
end

------------------------------
-- GUI system --
------------------------------
local COLORS = {
    bg = Color3.fromRGB(9, 13, 18),
    panel = Color3.fromRGB(16, 22, 29),
    panel2 = Color3.fromRGB(22, 30, 38),
    panel3 = Color3.fromRGB(28, 38, 47),
    line = Color3.fromRGB(48, 61, 70),
    text = Color3.fromRGB(235, 242, 245),
    muted = Color3.fromRGB(141, 157, 166),
    lime = Color3.fromRGB(174, 255, 62),
    limeDark = Color3.fromRGB(50, 91, 26),
    red = Color3.fromRGB(255, 98, 98),
    amber = Color3.fromRGB(255, 190, 78),
    blue = Color3.fromRGB(82, 190, 255),
}

local function create(className, properties, parent)
    local instance = Instance.new(className)
    for property, value in pairs(properties or {}) do
        pcall(function()
            instance[property] = value
        end)
    end
    instance.Parent = parent
    return instance
end

local function addCorner(parent, radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius or 12) }, parent)
end

local function addStroke(parent, color, transparency, thickness)
    return create("UIStroke", {
        Color = color or COLORS.line,
        Transparency = transparency or 0,
        Thickness = thickness or 1,
    }, parent)
end

local function addPadding(parent, left, right, top, bottom)
    return create("UIPadding", {
        PaddingLeft = UDim.new(0, left or 10),
        PaddingRight = UDim.new(0, right or 10),
        PaddingTop = UDim.new(0, top or 8),
        PaddingBottom = UDim.new(0, bottom or 8),
    }, parent)
end

local function makeLabel(parent, text, size, color, font)
    return create("TextLabel", {
        BackgroundTransparency = 1,
        Text = text or "",
        TextColor3 = color or COLORS.text,
        TextSize = size or 13,
        Font = font or Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = false,
        RichText = false,
    }, parent)
end

local function makeButton(parent, text, size, callback, primary)
    local button = create("TextButton", {
        AutoButtonColor = false,
        Text = text,
        TextColor3 = primary and COLORS.bg or COLORS.text,
        TextSize = 12,
        Font = Enum.Font.GothamBold,
        BackgroundColor3 = primary and COLORS.lime or COLORS.panel3,
        Size = size,
        BorderSizePixel = 0,
    }, parent)
    addCorner(button, 10)
    if not primary then
        addStroke(button, COLORS.line, 0.15, 1)
    end
    button.MouseButton1Click:Connect(function()
        if callback then callback() end
    end)
    button.MouseEnter:Connect(function()
        if button.Parent then
            TweenService:Create(button, TweenInfo.new(0.12), {
                BackgroundColor3 = primary and Color3.fromRGB(198, 255, 103) or COLORS.panel2,
            }):Play()
        end
    end)
    button.MouseLeave:Connect(function()
        if button.Parent then
            TweenService:Create(button, TweenInfo.new(0.12), {
                BackgroundColor3 = primary and COLORS.lime or COLORS.panel3,
            }):Play()
        end
    end)
    return button
end

local screenGui = create("ScreenGui", {
    Name = "MRA_HYBRID_091",
    ResetOnSpawn = false,
    IgnoreGuiInset = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
}, getExecutorGuiParent())
controller.ui = screenGui

local camera = workspace.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(720, 1280)
local mobileWidth = UserInputService.TouchEnabled and viewport.X < 800
local panelWidth = clamp(viewport.X * 0.93, 320, 580)
local panelHeight = clamp(viewport.Y * 0.72, 465, 650)

local root = create("Frame", {
    Name = "MainPanel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.52),
    Size = UDim2.fromOffset(panelWidth, panelHeight),
    BackgroundColor3 = COLORS.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, screenGui)
addCorner(root, 18)
addStroke(root, Color3.fromRGB(73, 96, 85), 0.15, 1.2)

local header = create("Frame", {
    Name = "Header",
    Active = true,
    BackgroundColor3 = COLORS.panel,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 58),
}, root)
create("Frame", {
    Name = "BarrageAccent",
    BackgroundColor3 = Color3.fromRGB(208, 55, 62),
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(0, 0),
    Size = UDim2.new(1, 0, 0, 2),
}, header)
addPadding(header, 14, 12, 6, 6)

local logoMark = create("Frame", {
    Size = UDim2.fromOffset(34, 34),
    Position = UDim2.fromOffset(0, 6),
    BackgroundColor3 = COLORS.lime,
    BorderSizePixel = 0,
}, header)
addCorner(logoMark, 10)
local logoText = makeLabel(logoMark, "M", 18, COLORS.bg, Enum.Font.GothamBlack)
logoText.Size = UDim2.fromScale(1, 1)
logoText.TextXAlignment = Enum.TextXAlignment.Center

local titleLabel = makeLabel(header, "MRA  /  MOTO RIDE ASSIST", 14, COLORS.text, Enum.Font.GothamBold)
titleLabel.Position = UDim2.fromOffset(44, 4)
titleLabel.Size = UDim2.new(1, -155, 0, 20)
local versionLabel = makeLabel(header, "ARES HYBRID  " .. VERSION .. "     •     APEX CONTROL", 9, COLORS.muted, Enum.Font.GothamMedium)
versionLabel.Position = UDim2.fromOffset(45, 25)
versionLabel.Size = UDim2.new(1, -155, 0, 16)

local minimizeButton = makeButton(header, "—", UDim2.fromOffset(30, 30), nil, false)
minimizeButton.Position = UDim2.new(1, -76, 0, 8)
local closeButton = makeButton(header, "×", UDim2.fromOffset(30, 30), nil, false)
closeButton.Position = UDim2.new(1, -38, 0, 8)
closeButton.TextSize = 18

local tabBar = create("Frame", {
    Name = "Tabs",
    BackgroundColor3 = COLORS.bg,
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(0, 58),
    Size = UDim2.new(1, 0, 0, 52),
}, root)
addPadding(tabBar, 10, 10, 4, 4)
local tabLayout = create("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, tabBar)

local contentHost = create("Frame", {
    Name = "ContentHost",
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(0, 110),
    Size = UDim2.new(1, 0, 1, -110),
}, root)

local pages = {}
local tabButtons = {}
local activeTab = "RIDE"

local function makePage(tabName)
    local page = create("ScrollingFrame", {
        Name = tabName .. "Page",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.lime,
        Visible = false,
    }, contentHost)
    addPadding(page, 12, 12, 10, 16)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 9),
    }, page)
    pages[tabName] = page
    return page
end

local function switchTab(tabName)
    activeTab = tabName
    for name, page in pairs(pages) do
        page.Visible = (name == tabName)
    end
    for name, button in pairs(tabButtons) do
        local selected = name == tabName
        button.BackgroundColor3 = selected and COLORS.limeDark or COLORS.panel
        button.TextColor3 = selected and COLORS.lime or COLORS.muted
        local stroke = button:FindFirstChildOfClass("UIStroke")
        if stroke then
            stroke.Color = selected and COLORS.lime or COLORS.line
            stroke.Transparency = selected and 0.2 or 0.65
        end
    end
end

for index, tabName in ipairs({ "RIDE", "BRAIN", "SETUP", "HEALTH" }) do
    local tabButton = create("TextButton", {
        Name = tabName .. "Tab",
        LayoutOrder = index,
        AutoButtonColor = false,
        BackgroundColor3 = COLORS.panel,
        Text = tabName,
        TextColor3 = COLORS.muted,
        TextSize = mobileWidth and 10 or 11,
        Font = Enum.Font.GothamBold,
        BorderSizePixel = 0,
        Size = UDim2.new(0.25, -5, 1, 0),
    }, tabBar)
    addCorner(tabButton, 9)
    addStroke(tabButton, COLORS.line, 0.6, 1)
    tabButton.MouseButton1Click:Connect(function()
        switchTab(tabName)
    end)
    tabButtons[tabName] = tabButton
    makePage(tabName)
end

local function makeCard(parent, height)
    local card = create("Frame", {
        BackgroundColor3 = COLORS.panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height),
    }, parent)
    addCorner(card, 13)
    addStroke(card, COLORS.line, 0.35, 1)
    addPadding(card, 12, 12, 10, 10)
    return card
end

local function makeSectionTitle(parent, text, subtext)
    local holder = create("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, subtext and 36 or 20),
    }, parent)
    local title = makeLabel(holder, text, 12, COLORS.text, Enum.Font.GothamBold)
    title.Size = UDim2.new(1, 0, 0, 18)
    if subtext then
        local sub = makeLabel(holder, subtext, 9, COLORS.muted, Enum.Font.Gotham)
        sub.Position = UDim2.fromOffset(0, 17)
        sub.Size = UDim2.new(1, 0, 0, 16)
    end
    return holder
end

local function makeStat(parent, labelText, valueText, accent)
    local frame = create("Frame", {
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
        Size = UDim2.new(0.5, -5, 0, 58),
    }, parent)
    addCorner(frame, 10)
    local label = makeLabel(frame, labelText, 9, COLORS.muted, Enum.Font.GothamBold)
    label.Position = UDim2.fromOffset(9, 7)
    label.Size = UDim2.new(1, -18, 0, 14)
    local value = makeLabel(frame, valueText, 14, accent or COLORS.text, Enum.Font.GothamBold)
    value.Position = UDim2.fromOffset(9, 24)
    value.Size = UDim2.new(1, -18, 0, 24)
    return value
end

local function makeToggle(parent, title, description, initial, callback)
    local row = create("Frame", {
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 62),
    }, parent)
    addCorner(row, 10)
    local titleLabel = makeLabel(row, title, 11, COLORS.text, Enum.Font.GothamBold)
    titleLabel.Position = UDim2.fromOffset(10, 7)
    titleLabel.Size = UDim2.new(1, -88, 0, 17)
    local descLabel = makeLabel(row, description or "", 8, COLORS.muted, Enum.Font.Gotham)
    descLabel.Position = UDim2.fromOffset(10, 26)
    descLabel.Size = UDim2.new(1, -88, 0, 14)

    local button = create("TextButton", {
        AutoButtonColor = false,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -9, 0.5, 0),
        Size = UDim2.fromOffset(78, 44),
        BackgroundColor3 = initial and COLORS.limeDark or COLORS.panel3,
        BorderSizePixel = 0,
        Text = initial and "ON" or "OFF",
        TextColor3 = initial and COLORS.lime or COLORS.muted,
        TextSize = 10,
        Font = Enum.Font.GothamBold,
    }, row)
    addCorner(button, 8)
    addStroke(button, initial and COLORS.lime or COLORS.line, 0.25, 1)

    local value = initial
    local function render()
        button.Text = value and "ON" or "OFF"
        button.BackgroundColor3 = value and COLORS.limeDark or COLORS.panel3
        button.TextColor3 = value and COLORS.lime or COLORS.muted
        local stroke = button:FindFirstChildOfClass("UIStroke")
        if stroke then
            stroke.Color = value and COLORS.lime or COLORS.line
        end
    end
    button.MouseButton1Click:Connect(function()
        value = not value
        render()
        if callback then callback(value) end
    end)
    return {
        row = row,
        button = button,
        get = function() return value end,
        set = function(newValue)
            value = not not newValue
            render()
        end,
    }
end

local function makeSlider(parent, title, minValue, maxValue, initial, step, suffix, callback)
    local card = create("Frame", {
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 74),
    }, parent)
    addCorner(card, 10)

    local titleLabel = makeLabel(card, title, 10, COLORS.text, Enum.Font.GothamBold)
    titleLabel.Position = UDim2.fromOffset(10, 7)
    titleLabel.Size = UDim2.new(1, -88, 0, 18)
    local valueLabel = makeLabel(card, tostring(initial) .. (suffix or ""), 10, COLORS.lime, Enum.Font.GothamBold)
    valueLabel.AnchorPoint = Vector2.new(1, 0)
    valueLabel.Position = UDim2.new(1, -10, 0, 7)
    valueLabel.Size = UDim2.fromOffset(72, 18)
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right

    local track = create("Frame", {
        BackgroundColor3 = COLORS.line,
        BorderSizePixel = 0,
        Active = true,
        Position = UDim2.fromOffset(10, 42),
        Size = UDim2.new(1, -20, 0, 8),
    }, card)
    addCorner(track, 5)
    local fill = create("Frame", {
        BackgroundColor3 = COLORS.lime,
        BorderSizePixel = 0,
        Size = UDim2.new((initial - minValue) / (maxValue - minValue), 0, 1, 0),
    }, track)
    addCorner(fill, 5)
    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new((initial - minValue) / (maxValue - minValue), 0, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        Active = true,
        BackgroundColor3 = COLORS.text,
        BorderSizePixel = 0,
    }, track)
    addCorner(knob, 8)
    addStroke(knob, COLORS.lime, 0, 2)
    -- Larger invisible hitbox makes the thin slider track usable with a thumb.
    local hitArea = create("Frame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Active = true,
        Position = UDim2.fromOffset(5, 29),
        Size = UDim2.new(1, -10, 0, 31),
        ZIndex = 5,
    }, card)

    local current = initial
    local dragging = false
    local function setFromX(x)
        local width = math.max(track.AbsoluteSize.X, 1)
        local ratio = clamp((x - track.AbsolutePosition.X) / width, 0, 1)
        local raw = minValue + (maxValue - minValue) * ratio
        local value = minValue + math.floor(((raw - minValue) / step) + 0.5) * step
        value = clamp(value, minValue, maxValue)
        if step < 1 then
            value = math.floor(value * 100 + 0.5) / 100
        else
            value = math.floor(value + 0.5)
        end
        current = value
        local finalRatio = (current - minValue) / (maxValue - minValue)
        fill.Size = UDim2.new(finalRatio, 0, 1, 0)
        knob.Position = UDim2.new(finalRatio, 0, 0.5, 0)
        valueLabel.Text = tostring(current) .. (suffix or "")
        if callback then callback(current) end
    end

    hitArea.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    addConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end))
    addConnection(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    return {
        card = card,
        get = function() return current end,
        set = function(value)
            current = clamp(value, minValue, maxValue)
            local ratio = (current - minValue) / (maxValue - minValue)
            fill.Size = UDim2.new(ratio, 0, 1, 0)
            knob.Position = UDim2.new(ratio, 0, 0.5, 0)
            valueLabel.Text = tostring(current) .. (suffix or "")
        end,
    }
end

local ridePage = pages.RIDE
local brainPage = pages.BRAIN
local setupPage = pages.SETUP
local healthPage = pages.HEALTH

------------------------------
-- RIDE page --
------------------------------
makeSectionTitle(ridePage, "RACE DECK", "LIVE CONTROL  /  NATIVE RACING LINE")
local statusCard = makeCard(ridePage, 83)
local statusHeading = makeLabel(statusCard, "SYSTEM STATUS", 9, COLORS.muted, Enum.Font.GothamBold)
statusHeading.Size = UDim2.new(1, 0, 0, 14)
local statusValue = makeLabel(statusCard, "STANDBY", 19, COLORS.lime, Enum.Font.GothamBlack)
statusValue.Position = UDim2.fromOffset(0, 17)
statusValue.Size = UDim2.new(1, -110, 0, 28)
local linePill = create("TextLabel", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, 0, 0, 17),
    Size = UDim2.fromOffset(104, 24),
    BackgroundColor3 = COLORS.panel3,
    BorderSizePixel = 0,
    Text = "LINE: WAITING",
    TextColor3 = COLORS.muted,
    TextSize = 8,
    Font = Enum.Font.GothamBold,
}, statusCard)
addCorner(linePill, 8)
local statusHint = makeLabel(statusCard, "AUTOMATION DISARMED  •  INPUT CHECK REQUIRED", 8, COLORS.muted, Enum.Font.Gotham)
statusHint.Position = UDim2.fromOffset(0, 51)
statusHint.Size = UDim2.new(1, 0, 0, 15)

local metricRow = create("Frame", {
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 58),
}, ridePage)
local metricLayout = create("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    Padding = UDim.new(0, 10),
}, metricRow)
local speedMetric = makeStat(metricRow, "SPEED", "0 km/h", COLORS.lime)
speedMetric.Parent.Size = UDim2.new(0.5, -5, 1, 0)
local offsetMetric = makeStat(metricRow, "LINE OFFSET", "0.0 st", COLORS.text)
offsetMetric.Parent.Size = UDim2.new(0.5, -5, 1, 0)

makeSectionTitle(ridePage, "AUTOMATION", "Toggle each controller independently")
local toggleSteer = makeToggle(ridePage, "AUTO STEER", "Predictive Pure Pursuit + corner feed-forward", false, function(value)
    State.autoSteer = value
    if not value then
        controller.filteredSteer = 0
        controller.activeSteerDirection = 0
        controller.steeringPulseEnds = 0
        releaseKey("A")
        releaseKey("D")
    end
    State.autoplay = State.autoSteer and State.autoBrake and State.autoThrottle
end)
local toggleBrake = makeToggle(ridePage, "AUTO BRAKE", "Predictive corner braking", false, function(value)
    State.autoBrake = value
    if not value then setBrake(0) end
    State.autoplay = State.autoSteer and State.autoBrake and State.autoThrottle
end)
local toggleThrottle = makeToggle(ridePage, "AUTO THROTTLE", "Speed-target throttle control", false, function(value)
    State.autoThrottle = value
    if not value then setThrottle(0) end
    State.autoplay = State.autoSteer and State.autoBrake and State.autoThrottle
end)

local autoplayButton = makeButton(ridePage, "▶   AUTOPLAY  /  ALL SYSTEMS", UDim2.new(1, 0, 0, 42), function()
    local enable = not (State.autoSteer and State.autoBrake and State.autoThrottle)
    State.autoSteer = enable
    State.autoBrake = enable
    State.autoThrottle = enable
    State.autoplay = enable
    toggleSteer.set(enable)
    toggleBrake.set(enable)
    toggleThrottle.set(enable)
    if not enable then
        releaseAll()
    end
end, true)

makeSectionTitle(ridePage, "STEERING TARGET", "1–100 native RacingLine points ahead of the bike")
local lookaheadSlider = makeSlider(ridePage, "LOOKAHEAD DISTANCE", 1, 100, CONFIG.Lookahead, 1, " PANAH", function(value)
    CONFIG.Lookahead = value
end)

local rideButtonsRow = create("Frame", {
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 36),
}, ridePage)
local rideButtonsLayout = create("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    Padding = UDim.new(0, 8),
}, rideButtonsRow)
local copyButton = makeButton(rideButtonsRow, "COPY LOG", UDim2.new(0.5, -4, 1, 0), function() end, false)
local recenterButton = makeButton(rideButtonsRow, "RESET TARGET", UDim2.new(0.5, -4, 1, 0), function()
    controller.nearestIndex = nil
    controller.filteredSteer = 0
    State.status = "TRACK REACQUIRE"
end, false)

------------------------------
-- BRAIN page --
------------------------------
makeSectionTitle(brainPage, "BRAIN TELEMETRY", "Controller values sampled from the live session")
local brainGrid = create("Frame", {
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 134),
}, brainPage)
local brainGridLayout = create("UIGridLayout", {
    CellSize = UDim2.new(0.5, -5, 0, 58),
    CellPadding = UDim2.fromOffset(10, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, brainGrid)
local nearestMetric = makeStat(brainGrid, "NEAREST POINT", "-", COLORS.text)
local targetMetric = makeStat(brainGrid, "TARGET POINT", "-", COLORS.lime)
local headingMetric = makeStat(brainGrid, "HEADING ERROR", "0.0°", COLORS.text)
local cornerMetric = makeStat(brainGrid, "NEXT CORNER", "STRAIGHT", COLORS.amber)

local brainDetail = makeCard(brainPage, 112)
makeSectionTitle(brainDetail, "STEERING RESPONSE", "Raw request vs filtered controller output")
local rawValue = makeLabel(brainDetail, "RAW      0.000", 10, COLORS.muted, Enum.Font.GothamBold)
rawValue.Position = UDim2.fromOffset(0, 42)
rawValue.Size = UDim2.new(1, 0, 0, 16)
local filteredValue = makeLabel(brainDetail, "FILTERED  0.000", 10, COLORS.lime, Enum.Font.GothamBold)
filteredValue.Position = UDim2.fromOffset(0, 63)
filteredValue.Size = UDim2.new(1, 0, 0, 16)
local brakeValue = makeLabel(brainDetail, "BRAKE     0%", 10, COLORS.amber, Enum.Font.GothamBold)
brakeValue.Position = UDim2.fromOffset(0, 84)
brakeValue.Size = UDim2.new(1, 0, 0, 16)

local lineDetail = makeCard(brainPage, 80)
makeSectionTitle(lineDetail, "TRACK PROGRESS", "Forward-tracked native point index")
local progressValue = makeLabel(lineDetail, "0 / 0   •   TARGET +5", 11, COLORS.text, Enum.Font.GothamBold)
progressValue.Position = UDim2.fromOffset(0, 43)
progressValue.Size = UDim2.new(1, 0, 0, 18)

local cornerDetail = makeCard(brainPage, 76)
makeSectionTitle(cornerDetail, "CORNER PHASE", "First upcoming bend / predictive entry")
local cornerPhaseValue = makeLabel(cornerDetail, "STRAIGHT  •  NONE  •  FF 0.000", 10, COLORS.lime, Enum.Font.GothamBold)
cornerPhaseValue.Position = UDim2.fromOffset(0, 43)
cornerPhaseValue.Size = UDim2.new(1, 0, 0, 15)
local yawValue = makeLabel(cornerDetail, "YAW RATE  0.0°/s", 9, COLORS.muted, Enum.Font.Gotham)
yawValue.Position = UDim2.fromOffset(0, 58)
yawValue.Size = UDim2.new(1, 0, 0, 13)

------------------------------
-- SETUP page --
------------------------------
makeSectionTitle(setupPage, "CONTROLLER SETUP", "Tune response without editing the script")
local sensSlider = makeSlider(setupPage, "STEERING SENSITIVITY", 0.50, 1.80, CONFIG.SteeringSensitivity, 0.05, "×", function(value)
    CONFIG.SteeringSensitivity = value
end)
local smoothSlider = makeSlider(setupPage, "STEERING SMOOTHING", 0.05, 0.45, CONFIG.SteeringSmoothing, 0.01, "s", function(value)
    CONFIG.SteeringSmoothing = value
end)
local crossTrackSlider = makeSlider(setupPage, "LINE CORRECTION", 0.02, 0.12, CONFIG.CrossTrackGain, 0.005, "", function(value)
    CONFIG.CrossTrackGain = value
end)
local brakeSlider = makeSlider(setupPage, "BRAKE AGGRESSION", 0.50, 1.50, CONFIG.BrakeAggression, 0.05, "×", function(value)
    CONFIG.BrakeAggression = value
end)
local topSpeedSlider = makeSlider(setupPage, "TARGET TOP SPEED", 100, 300, CONFIG.ThrottleTopSpeedKph, 5, " km/h", function(value)
    CONFIG.ThrottleTopSpeedKph = value
    -- MRA speed cap is authoritative; the track module does not expose this field.
end)

local setupNote = makeCard(setupPage, 74)
makeSectionTitle(setupNote, "TUNING NOTE", "Change one setting at a time")
local setupText = makeLabel(setupNote, "Lookahead is 1–100 generated line samples. Dynamic planner uses Track Layout geometry; native RacingLine is fallback. Top speed cap: 300 km/h.", 9, COLORS.muted, Enum.Font.Gotham)
setupText.Position = UDim2.fromOffset(0, 39)
setupText.Size = UDim2.new(1, 0, 0, 28)
setupText.TextWrapped = true

------------------------------
-- HEALTH page --
------------------------------
makeSectionTitle(healthPage, "SYSTEM HEALTH", "Runtime diagnostics  /  no fake success states")
local healthGrid = create("Frame", {
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 134),
}, healthPage)
create("UIGridLayout", {
    CellSize = UDim2.new(0.5, -5, 0, 58),
    CellPadding = UDim2.fromOffset(10, 8),
}, healthGrid)
local inputHealth = makeStat(healthGrid, "INPUT BRIDGE", "UNKNOWN", COLORS.amber)
local lineHealth = makeStat(healthGrid, "RACING LINE", "WAITING", COLORS.muted)
local bikeHealth = makeStat(healthGrid, "VEHICLE", "NOT SEATED", COLORS.muted)
local errorHealth = makeStat(healthGrid, "LAST ERROR", "-", COLORS.text)

local healthDetail = makeCard(healthPage, 96)
makeSectionTitle(healthDetail, "SAFETY STATUS", "Keys are released when automation is disarmed")
local safetyValue = makeLabel(healthDetail, "ALL CONTROLLERS OFF", 10, COLORS.muted, Enum.Font.GothamBold)
safetyValue.Position = UDim2.fromOffset(0, 43)
safetyValue.Size = UDim2.new(1, 0, 0, 18)
local bridgeNote = makeLabel(healthDetail, "API call success is not proof that game input was accepted.", 8, COLORS.amber, Enum.Font.Gotham)
bridgeNote.Position = UDim2.fromOffset(0, 65)
bridgeNote.Size = UDim2.new(1, 0, 0, 15)

------------------------------
-- Minimize / restore / drag --
------------------------------
local restoreButton = create("TextButton", {
    Name = "RestoreMRA",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -16, 1, -90),
    Size = UDim2.fromOffset(62, 42),
    BackgroundColor3 = COLORS.lime,
    Text = "MRA",
    TextColor3 = COLORS.bg,
    TextSize = 13,
    Font = Enum.Font.GothamBlack,
    Visible = false,
    BorderSizePixel = 0,
}, screenGui)
addCorner(restoreButton, 12)
addStroke(restoreButton, COLORS.text, 0.3, 1)

minimizeButton.MouseButton1Click:Connect(function()
    root.Visible = false
    restoreButton.Visible = true
end)
restoreButton.MouseButton1Click:Connect(function()
    root.Visible = true
    restoreButton.Visible = false
end)

local dragging = false
local dragInput = nil
local dragStart = nil
local startPosition = nil
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragInput = input
        dragStart = input.Position
        startPosition = root.Position
    end
end)
header.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
addConnection(UserInputService.InputChanged:Connect(function(input)
    if dragging and dragStart and startPosition and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        root.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end))
addConnection(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
        dragInput = nil
    end
end))

-- Raw input capture is intentionally separate from automation. Mobile touch
-- controls remain UNKNOWN until their actual GUI regions are calibrated.
addConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    local event = pushInputEvent("PRESS", input, gameProcessed and "GAME_PROCESSED" or "")
    if event then
        event.gameProcessed = gameProcessed == true
        State.activeInputEvents[input] = event
    end
end))
addConnection(UserInputService.InputEnded:Connect(function(input, gameProcessed)
    local pressEvent = State.activeInputEvents[input]
    local event = pushInputEvent("RELEASE", input, gameProcessed and "GAME_PROCESSED" or "")
    if event then
        event.gameProcessed = gameProcessed == true
        if pressEvent then event.holdDurationSec = math.max(0, event.timeSec - (pressEvent.timeSec or event.timeSec)) end
    end
    State.activeInputEvents[input] = nil
end))
addConnection(UserInputService.WindowFocusReleased:Connect(function()
    cancelActiveInputs("WINDOW_FOCUS_LOST")
end))

------------------------------
-- GUI copy / shutdown --
------------------------------
local function buildDiagnosticText()
    return table.concat({
        "ARES HYBRID " .. VERSION,
        "Status: " .. tostring(State.status),
        "Line: " .. tostring(State.lineStatus),
        "Planner: " .. tostring(State.lineMode),
        "Track: " .. tostring(State.trackName),
        "Grip estimate: " .. string.format("%.2f", State.gripEstimate),
        "Input: " .. tostring(State.inputStatus),
        "Bike: " .. tostring(State.bikeStatus),
        "Speed: " .. string.format("%.1f", State.speedKph) .. " km/h",
        "Offset: " .. string.format("%.2f", State.offset),
        "Lookahead: " .. tostring(CONFIG.Lookahead),
        "Top speed cap: " .. tostring(CONFIG.ThrottleTopSpeedKph) .. " km/h",
        "Nearest: " .. tostring(State.nearestIndex),
        "Target: " .. tostring(State.targetIndex),
        "Steer: " .. string.format("%.3f", State.steer),
        "Brake: " .. string.format("%.2f", State.brake),
        "Throttle: " .. string.format("%.2f", State.throttle),
        "Recorder: ARES_EVENT_V2 / " .. tostring(#State.inputEvents) .. " events (touch controls UNKNOWN until calibrated)",
        "Recent input events (JSONL):",
        (function()
            local rows = {}
            local first = math.max(1, #State.inputEvents - 79)
            for i = first, #State.inputEvents do
                local ok, encoded = pcall(function() return HttpService:JSONEncode(State.inputEvents[i]) end)
                rows[#rows + 1] = ok and encoded or "{}"
            end
            return table.concat(rows, "\n")
        end)(),
        "Error: " .. tostring(State.errorText),
    }, "\n")
end

copyButton.MouseButton1Click:Connect(function()
    local diagnostic = buildDiagnosticText()
    local clipboardFunction = setclipboard or toclipboard
    if type(clipboardFunction) == "function" then
        local ok = pcall(clipboardFunction, diagnostic)
        statusHint.Text = ok and "DIAGNOSTIC COPIED" or "CLIPBOARD CALL FAILED"
    else
        statusHint.Text = "CLIPBOARD API UNAVAILABLE"
    end
end)

local function shutdown(reason)
    if not State.alive then return end
    State.alive = false
    State.enabled = false
    State.autoSteer = false
    State.autoBrake = false
    State.autoThrottle = false
    State.autoplay = false
    cancelActiveInputs("SCRIPT_SHUTDOWN")
    releaseAll()
    -- One more release pass before removing the UI/loop, in case the first
    -- bridge release call transiently failed.
    releaseAll()
    for _, connection in ipairs(controller.connections) do
        safeDisconnect(connection)
    end
    if reason then
        State.status = reason
    end
    pcall(function()
        screenGui:Destroy()
    end)
end

closeButton.MouseButton1Click:Connect(function()
    shutdown("CLOSED")
end)

------------------------------
-- State update / heartbeat --
------------------------------
local function updateGui()
    if not State.alive or not screenGui.Parent then return end
    local isActive = State.autoSteer or State.autoBrake or State.autoThrottle
    statusValue.Text = State.status
    statusValue.TextColor3 = State.status == "ARMED" and COLORS.lime or (State.status:find("ERROR") and COLORS.red or COLORS.text)
    linePill.Text = "LINE: " .. State.lineStatus
    linePill.TextColor3 = State.lineStatus == "NATIVE READY" and COLORS.lime or COLORS.amber
    statusHint.Text = isActive and "AUTOMATION ARMED  •  MONITOR INPUT FEEDBACK" or "AUTOMATION DISARMED  •  INPUTS RELEASED"

    speedMetric.Text = string.format("%.0f km/h", State.speedKph)
    offsetMetric.Text = string.format("%.1f st", State.offset)
    nearestMetric.Text = tostring(State.nearestIndex or "-")
    targetMetric.Text = tostring(State.targetIndex or "-")
    headingMetric.Text = string.format("%.1f°", State.headingError)
    cornerMetric.Text = State.cornerLabel
    cornerPhaseValue.Text = string.format("%s  •  %s  •  ENTRY %.0fst  •  FF %.3f",
        State.cornerPhase, State.cornerDirection, State.cornerDistance, State.cornerFeedForward)
    yawValue.Text = string.format("YAW RATE  %.1f°/s", State.yawRateDeg)
    rawValue.Text = string.format("RAW      %.3f", State.steerRaw)
    filteredValue.Text = string.format("FILTERED  %.3f", State.steer)
    brakeValue.Text = string.format("BRAKE     %d%%", math.floor(State.brake * 100 + 0.5))
    progressValue.Text = string.format("%d / %d   •   TARGET +%d   •   SEG %.2f",
        State.nearestIndex or 0, State.lineCount or 0, CONFIG.Lookahead, State.segmentAlpha or 0)

    inputHealth.Text = State.inputStatus
    inputHealth.TextColor3 = State.inputFault and COLORS.red or COLORS.amber
    lineHealth.Text = State.lineStatus
    lineHealth.TextColor3 = State.lineStatus == "NATIVE READY" and COLORS.lime or COLORS.muted
    bikeHealth.Text = State.bikeStatus
    bikeHealth.TextColor3 = State.bikeStatus == "RIDERSEAT FOUND" and COLORS.lime or COLORS.muted
    errorHealth.Text = string.sub(tostring(State.errorText), 1, 18)
    safetyValue.Text = isActive and "AUTOMATION ARMED" or "ALL CONTROLLERS OFF"
    safetyValue.TextColor3 = isActive and COLORS.lime or COLORS.muted
end

local function safeControllerStep(dt)
    local ok, err = pcall(controllerStep, dt)
    if not ok then
        State.errorText = tostring(err)
        State.status = "ERROR / INPUT RELEASE"
        State.inputFault = true
        releaseAll()
    end
end

addConnection(RunService.Heartbeat:Connect(function()
    if not State.alive then return end
    local t = now()
    if t < controller.nextStepAt then
        return
    end

    local dt = controller.lastStepAt > 0 and (t - controller.lastStepAt) or CONFIG.UpdateInterval
    controller.lastStepAt = t
    controller.nextStepAt = t + CONFIG.UpdateInterval
    State.dt = dt

    safeControllerStep(dt)

    if t - State.lastUiUpdate > 0.12 then
        State.lastUiUpdate = t
        updateGui()
    end
end))

addConnection(LocalPlayer.CharacterAdded:Connect(function()
    controller.nearestIndex = nil
    controller.filteredSteer = 0
    State.bikeStatus = "RESPAWNING"
    releaseAll()
end))

addConnection(LocalPlayer.CharacterRemoving:Connect(function()
    cancelActiveInputs("CHARACTER_REMOVING")
    releaseAll()
    controller.nearestIndex = nil
    State.bikeStatus = "CHARACTER REMOVED"
end))

-- Initial bridge probe: this reports only API call status, not game acceptance.
do
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.A, false, game)
    end)
    State.inputStatus = ok and "API CALL OK / GAME ACK UNKNOWN" or "VIM UNAVAILABLE"
    State.inputFault = not ok
end

switchTab("RIDE")
updateGui()

-- The first line read is informational; automation remains off until enabled.
task.spawn(function()
    loadLine(true)
    updateGui()
end)

print("[ARES] HYBRID " .. VERSION .. " loaded. Automation is OFF by default.")
