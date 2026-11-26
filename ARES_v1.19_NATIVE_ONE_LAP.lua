--[[
    ARES v1.19 | NATIVE ONE-LAP SUPERVISOR
    Moto Legends / Roblox mobile

    CONTROL OWNERSHIP:
      - Native Moto Legends AutoPilotClient owns steering, throttle, brake and lean.
      - ARES does NOT use VirtualInputManager and does NOT write bike control fields.
      - ARES prepares the native AutoPilot session descriptor, monitors native output,
        tracks one complete RacingLine loop, and clears the session on finish/fault.

    SOURCE BASIS:
      - ReplicatedStorage.MotoLegends.AutoPilot: Profile(), Build() profile data.
      - Native AutoPilotClient: Player attribute "AutoPilot" is parsed as
        startIndex,endIndex,spawnToken,initialSpeed[,...].
      - Native AutoPilotClient exposes shared.MotoAutoPilot() and updates
        shared.MotoAutoPilotOut while its native controller is producing controls.

    IMPORTANT:
      - The supplied source confirms the attribute parser and controller hook,
        but this exact supervisor has not been executed in the live game.
      - Start is refused unless a RiderSeat, RacingLine profile, numeric SpawnToken,
        and native shared.MotoAutoPilot hook are all present.
      - The script clears only the AutoPilot attribute payload it created.
      - Stop the older ARES v1.16/v1.18 controller before running this script.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LP = Players.LocalPlayer
local GUI_NAME = "ARES_v119_NativeSupervisor"
local ATTRIBUTE_NAME = "AutoPilot"

-- Disconnect a previous copy of this supervisor before replacing its GUI.
pcall(function()
    if type(shared.ARESv119Shutdown) == "function" then
        shared.ARESv119Shutdown()
    end
end)

-- Prevent duplicate supervisor GUIs/loops from repeated execution.
local oldSupervisor = nil
for _, root in ipairs({CoreGui, LP:FindFirstChildOfClass("PlayerGui")}) do
    if root then
        oldSupervisor = root:FindFirstChild(GUI_NAME)
        if oldSupervisor then oldSupervisor:Destroy() end
    end
end

local State = {
    active = false,
    closed = false,
    armedAt = 0,
    payload = nil,
    nativeSeen = false,
    lastNativeAt = 0,
    profile = nil,
    points = nil,
    count = 0,
    ds = nil,
    startIndex = nil,
    endIndex = nil,
    lastIndex = nil,
    progressStuds = 0,
    targetStuds = 0,
    averageSpacing = 0,
    offLineSince = nil,
    lastUpdate = 0,
    status = "STANDBY",
    detail = "Stop older ARES controller before starting",
    speed = 0,
    lineDistance = 0,
    lapPercent = 0,
    trackName = "NATIVE RACING LINE",
}

local connections = {}
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local function horizontal(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function wrapIndex(index, count)
    return ((index - 1) % count) + 1
end

local function getBike()
    local character = LP.Character
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return nil end
    local seat = humanoid.SeatPart
    if not seat or seat.Name ~= "RiderSeat" then return nil end
    local root = seat.AssemblyRootPart or seat
    return seat, root
end

-- Native AutoPilotClient compares its third descriptor field against
-- p371:GetAttribute("SpawnToken"). The RiderSeat's containing bike model is
-- expected to be an ancestor of that instance, so search upward and require
-- a numeric token accepted by the native parser (%d+).
local function findSpawnToken(seat)
    local cursor = seat
    for _ = 1, 12 do
        if not cursor then break end
        local token = cursor:GetAttribute("SpawnToken")
        if token ~= nil then
            -- The native client parses the descriptor token with tonumber(),
            -- then compares it directly to GetAttribute(); require a numeric
            -- Roblox attribute rather than a digit-looking string.
            if typeof(token) == "number" and token >= 0 and token % 1 == 0 then
                return tostring(token), cursor
            end
        end
        cursor = cursor.Parent
    end
    return nil, nil
end

local function loadNativeProfile()
    local moto = ReplicatedStorage:FindFirstChild("MotoLegends")
    assert(moto, "ReplicatedStorage.MotoLegends missing")

    local racingLineModule = moto:FindFirstChild("RacingLine")
    assert(racingLineModule and racingLineModule:IsA("ModuleScript"), "RacingLine ModuleScript missing")

    local autoPilotModule = moto:FindFirstChild("AutoPilot")
    assert(autoPilotModule and autoPilotModule:IsA("ModuleScript"), "AutoPilot ModuleScript missing")

    local racingLine = require(racingLineModule)
    assert(type(racingLine.Get) == "function", "RacingLine.Get unavailable")

    local autoPilot = require(autoPilotModule)
    assert(type(autoPilot.Profile) == "function", "AutoPilot.Profile unavailable")

    local wet = moto:GetAttribute("Raining") == true
    local trackName = "UNKNOWN TRACK"
    local configModule = moto:FindFirstChild("Config")
    if configModule and configModule:IsA("ModuleScript") then
        local config = require(configModule)
        if type(config) == "table" and type(config.Track) == "string" then
            trackName = config.Track
        end
    end

    local profile = autoPilot.Profile(wet)
    assert(type(profile) == "table", "Native AutoPilot.Profile returned no data")
    assert(type(profile.points) == "table", "Native profile points missing")
    assert(type(profile.ds) == "table", "Native profile segment distances missing")
    assert(type(profile.n) == "number" and profile.n >= 8, "Native profile point count invalid")

    for index = 1, profile.n do
        assert(typeof(profile.points[index]) == "Vector3", "Invalid RacingLine point " .. tostring(index))
        assert(type(profile.ds[index]) == "number" and profile.ds[index] > 0, "Invalid segment distance " .. tostring(index))
    end

    return profile, wet, trackName
end

local function findNearestGlobal(points, count, position)
    local bestIndex = nil
    local bestDistance = math.huge
    for index = 1, count do
        local point = points[index]
        local distance = horizontal(point - position).Magnitude
        if distance < bestDistance then
            bestDistance = distance
            bestIndex = index
        end
    end
    return bestIndex, bestDistance
end

local function findNearestForward(points, count, position, previousIndex)
    local bestIndex = nil
    local bestDistance = math.huge
    -- A short rear allowance prevents point-index jitter; the rest of the
    -- search follows the native RacingLine direction.
    for offset = -8, math.min(320, count - 1) do
        local index = wrapIndex(previousIndex + offset, count)
        local distance = horizontal(points[index] - position).Magnitude
        if distance < bestDistance then
            bestDistance = distance
            bestIndex = index
        end
    end
    return bestIndex, bestDistance
end

local function getNativeOutput()
    local ok, output = pcall(function()
        return shared.MotoAutoPilotOut
    end)
    if ok and type(output) == "table" then return output end
    return nil
end

local function safeClearOwnAttribute()
    if State.payload then
        local ok, current = pcall(function()
            return LP:GetAttribute(ATTRIBUTE_NAME)
        end)
        if ok and current == State.payload then
            pcall(function()
                LP:SetAttribute(ATTRIBUTE_NAME, nil)
            end)
        end
    end
end

local function stopSupervisor(reason, clearNative)
    if not State.active then
        State.status = reason or State.status
        return
    end

    State.active = false
    if clearNative ~= false then
        safeClearOwnAttribute()
    end

    State.status = reason or "STOPPED"
    State.detail = "Native control session released"
    State.payload = nil
    State.offLineSince = nil
end

-- UI -----------------------------------------------------------------------
local playerGui = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1001
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local parentOK = pcall(function() gui.Parent = CoreGui end)
if not parentOK or not gui.Parent then gui.Parent = playerGui end

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(292, 188)
panel.Position = UDim2.new(0, 16, 0.38, 0)
panel.BackgroundColor3 = Color3.fromRGB(18, 23, 31)
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
local panelStroke = Instance.new("UIStroke", panel)
panelStroke.Color = Color3.fromRGB(73, 100, 125)
panelStroke.Thickness = 1

local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 30)
top.BackgroundColor3 = Color3.fromRGB(31, 43, 57)
top.BorderSizePixel = 0
top.Parent = panel
Instance.new("UICorner", top).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(10, 0)
title.Size = UDim2.new(1, -20, 1, 0)
title.Font = Enum.Font.GothamBold
title.Text = "ARES 1.19  |  NATIVE ONE LAP"
title.TextSize = 11
title.TextColor3 = Color3.fromRGB(235, 242, 250)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = top

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(11, 38)
statusLabel.Size = UDim2.new(1, -22, 0, 20)
statusLabel.Font = Enum.Font.GothamBold
statusLabel.Text = "STATUS: STANDBY"
statusLabel.TextSize = 11
statusLabel.TextColor3 = Color3.fromRGB(210, 224, 236)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = panel

local detailLabel = Instance.new("TextLabel")
detailLabel.BackgroundTransparency = 1
detailLabel.Position = UDim2.fromOffset(11, 62)
detailLabel.Size = UDim2.new(1, -22, 0, 76)
detailLabel.Font = Enum.Font.Code
detailLabel.Text = "CONTROL: NATIVE ONLY\nLINE: WAITING\nLAP: 0.0%\nSPEED: 0.0 studs/s"
detailLabel.TextSize = 10
detailLabel.TextColor3 = Color3.fromRGB(164, 186, 205)
detailLabel.TextXAlignment = Enum.TextXAlignment.Left
detailLabel.TextYAlignment = Enum.TextYAlignment.Top
detailLabel.Parent = panel

local function makeButton(text, position, size, color)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = color
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.Text = text
    button.TextSize = 10
    button.TextColor3 = Color3.new(1, 1, 1)
    button.AutoButtonColor = true
    button.Parent = panel
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
    return button
end

local startButton = makeButton(
    "START 1 LAP (NATIVE)",
    UDim2.fromOffset(11, 145),
    UDim2.new(0.63, -6, 0, 30),
    Color3.fromRGB(49, 111, 76)
)
local stopButton = makeButton(
    "STOP",
    UDim2.new(0.63, 6, 0, 145),
    UDim2.new(0.37, -17, 0, 30),
    Color3.fromRGB(145, 62, 62)
)

-- Drag panel on touch or mouse.
local dragging = false
local dragInputPosition = nil
local dragFramePosition = nil
connect(top.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragInputPosition = input.Position
        dragFramePosition = panel.Position
    end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragInputPosition
        panel.Position = UDim2.new(
            dragFramePosition.X.Scale,
            dragFramePosition.X.Offset + delta.X,
            dragFramePosition.Y.Scale,
            dragFramePosition.Y.Offset + delta.Y
        )
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

local function startOneLap()
    if State.closed then return end
    if State.active then
        State.status = "ALREADY RUNNING"
        return
    end

    local existing = LP:GetAttribute(ATTRIBUTE_NAME)
    if existing ~= nil and tostring(existing) ~= "" then
        State.status = "NATIVE BUSY"
        State.detail = "AutoPilot attribute already set; stop the existing game session first"
        return
    end

    local hookOK, nativeHook = pcall(function()
        return shared.MotoAutoPilot
    end)
    if not hookOK or type(nativeHook) ~= "function" then
        State.status = "NATIVE CLIENT MISSING"
        State.detail = "shared.MotoAutoPilot hook not found; native controller is not ready"
        return
    end

    local seat, root = getBike()
    if not seat then
        State.status = "WAITING FOR BIKE"
        State.detail = "Sit on the bike; RiderSeat is required"
        return
    end

    local tokenText, tokenHolder = findSpawnToken(seat)
    if not tokenText then
        State.status = "SPAWN TOKEN MISSING"
        State.detail = "No numeric SpawnToken attribute found on the RiderSeat ancestor chain"
        return
    end

    local profileOK, profileOrError, wet, trackName = pcall(loadNativeProfile)
    if not profileOK then
        State.status = "PROFILE ERROR"
        State.detail = string.sub(tostring(profileOrError), 1, 100)
        return
    end

    local profile = profileOrError
    local position = root.Position
    local startIndex, distance = findNearestGlobal(profile.points, profile.n, position)
    if not startIndex or distance > 100 then
        State.status = "OFF RACING LINE"
        State.detail = string.format("Nearest native line point is %.1f studs away", distance or math.huge)
        return
    end

    -- Native AutoPilotClient computes total = (endIndex - startIndex) % n.
    -- Choosing the point immediately before startIndex creates a one-loop
    -- path segment (n-1 native segments) from the current RacingLine location.
    local endIndex = wrapIndex(startIndex - 1, profile.n)
    local totalDistance = 0
    local totalTrackDistance = 0
    for index = 1, profile.n do
        totalTrackDistance += profile.ds[index]
    end
    for step = 0, profile.n - 2 do
        local index = wrapIndex(startIndex + step, profile.n)
        totalDistance += profile.ds[index]
    end
    if totalDistance <= 0 or totalTrackDistance <= 0 then
        State.status = "INVALID TRACK LENGTH"
        State.detail = "Native profile segment distances are invalid"
        return
    end

    local velocity = horizontal(root.AssemblyLinearVelocity).Magnitude
    if velocity ~= velocity or velocity == math.huge then velocity = 0 end
    local payload = string.format("%d,%d,%s,%.6f", startIndex, endIndex, tokenText, velocity)

    State.profile = profile
    State.points = profile.points
    State.ds = profile.ds
    State.count = profile.n
    State.startIndex = startIndex
    State.endIndex = endIndex
    State.lastIndex = startIndex
    State.progressStuds = 0
    State.targetStuds = totalDistance
    State.averageSpacing = totalTrackDistance / profile.n
    State.offLineSince = nil
    State.nativeSeen = false
    State.lastNativeAt = 0
    State.armedAt = os.clock()
    State.payload = payload
    State.speed = velocity
    State.lineDistance = distance
    State.lapPercent = 0
    State.trackName = trackName or "UNKNOWN TRACK"

    local setOK, setError = pcall(function()
        LP:SetAttribute(ATTRIBUTE_NAME, payload)
    end)
    if not setOK then
        State.payload = nil
        State.status = "ARM FAILED"
        State.detail = tostring(setError)
        return
    end

    State.active = true
    State.status = "ARMING NATIVE"
    State.detail = string.format("%s | native session %d -> %d", State.trackName, startIndex, endIndex)
end

connect(startButton.Activated, startOneLap)
connect(stopButton.Activated, function()
    stopSupervisor("STOPPED BY USER", true)
end)

-- Main supervisor loop. This script never writes throttle/steer/brake/lean.
connect(RunService.Heartbeat, function(dt)
    if State.closed then return end

    local now = os.clock()
    if now - State.lastUpdate < 0.05 then return end
    State.lastUpdate = now

    if State.active then
        local seat, root = getBike()
        if not seat or not root then
            stopSupervisor("BIKE LOST / SESSION RELEASED", true)
        else
            State.speed = horizontal(root.AssemblyLinearVelocity).Magnitude

            local currentAttribute = LP:GetAttribute(ATTRIBUTE_NAME)
            if currentAttribute ~= State.payload then
                if State.lapPercent >= 99.5 then
                    stopSupervisor("ONE LAP COMPLETE", false)
                else
                    stopSupervisor("NATIVE SESSION ENDED EARLY", false)
                    State.detail = string.format("Native stopped at %.1f%% lap progress", State.lapPercent)
                end
            else
                local output = getNativeOutput()
                if output and type(output.at) == "number" and output.at >= State.armedAt then
                    State.nativeSeen = true
                    State.lastNativeAt = output.at
                    State.status = "NATIVE AUTOPILOT RUNNING"
                elseif not State.nativeSeen and now - State.armedAt > 4 then
                    stopSupervisor("NATIVE HOOK DID NOT RESPOND", true)
                    State.detail = "AutoPilot attribute was set, but native output never appeared"
                elseif State.nativeSeen and now - State.lastNativeAt > 1.2 then
                    if State.lapPercent >= 99.5 then
                        stopSupervisor("ONE LAP COMPLETE", true)
                    else
                        stopSupervisor("NATIVE OUTPUT LOST", true)
                        State.detail = string.format("Native output stale; lap progress %.1f%%", State.lapPercent)
                    end
                else
                    local index, distance = findNearestForward(
                        State.points, State.count, root.Position, State.lastIndex
                    )
                    State.lineDistance = distance or math.huge

                    if distance and distance > 85 then
                        if not State.offLineSince then State.offLineSince = now end
                        if now - State.offLineSince > 1.5 then
                            stopSupervisor("OFF LINE / NATIVE RELEASED", true)
                            State.detail = string.format("RacingLine distance %.1f studs", distance)
                        end
                    else
                        State.offLineSince = nil
                    end

                    if State.active and index and distance and distance <= 85 then
                        local delta = (index - State.lastIndex) % State.count
                        if delta > 0 and delta <= math.min(400, math.floor(State.count / 2)) then
                            for step = 0, delta - 1 do
                                local segmentIndex = wrapIndex(State.lastIndex + step, State.count)
                                State.progressStuds += State.ds[segmentIndex]
                            end
                            State.lastIndex = index
                        elseif delta >= State.count - 8 then
                            -- Small backward nearest-point jitter: ignore it.
                        elseif delta > math.floor(State.count / 2) then
                            -- Ambiguous jump to another portion of the loop; do not
                            -- count it as progress. The native controller remains owner.
                        elseif delta > 0 then
                            -- A large forward jump means localization skipped too much
                            -- geometry to certify a full lap safely.
                            stopSupervisor("TRACK PROGRESS LOST", true)
                            State.detail = "Forward RacingLine index jump exceeded supervisor limit"
                        end
                    end

                    State.lapPercent = math.clamp(
                        (State.progressStuds / math.max(State.targetStuds, 1)) * 100,
                        0,
                        100
                    )

                    local finishTolerance = math.max(State.averageSpacing * 3, State.targetStuds * 0.002)
                    if State.active and State.progressStuds >= State.targetStuds - finishTolerance then
                        stopSupervisor("ONE LAP COMPLETE", true)
                        State.lapPercent = 100
                        State.detail = "Finish crossing detected; native AutoPilot session cleared"
                    end
                end
            end
        end
    end

    local output = getNativeOutput()
    local controlText = State.active and (State.nativeSeen and "NATIVE ACTIVE" or "NATIVE ARMING") or "NATIVE ONLY / IDLE"
    local lapText = string.format("LAP: %.1f%%  (%d -> %d)", State.lapPercent,
        State.startIndex or 0, State.endIndex or 0)
    local outText = output and "OUTPUT: LIVE" or "OUTPUT: --"
    statusLabel.Text = "STATUS: " .. State.status
    detailLabel.Text = string.format(
        "CONTROL: %s\n%s\n%s\nSPD: %.1f studs/s  LINE: %.1f\nTRACK: %s\n%s",
        controlText,
        lapText,
        outText,
        State.speed,
        State.lineDistance,
        tostring(State.trackName),
        string.sub(State.detail or "", 1, 54)
    )

    startButton.Text = State.active and "NATIVE LAP RUNNING" or "START 1 LAP (NATIVE)"
    startButton.BackgroundColor3 = State.active and Color3.fromRGB(120, 91, 43) or Color3.fromRGB(49, 111, 76)
end)

connect(LP.CharacterAdded, function()
    if State.active then
        stopSupervisor("RESPAWN / NATIVE RELEASED", true)
    end
end)

local function shutdown()
    if State.closed then return end
    stopSupervisor("CLOSED", true)
    State.closed = true
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
    pcall(function() gui:Destroy() end)
    pcall(function()
        if shared.ARESv119Shutdown == shutdown then
            shared.ARESv119Shutdown = nil
        end
    end)
end

pcall(function()
    shared.ARESv119Shutdown = shutdown
end)

-- Closing the supervisor GUI is equivalent to releasing the native session.
local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(24, 22)
closeButton.Position = UDim2.new(1, -28, 0, 4)
closeButton.BackgroundColor3 = Color3.fromRGB(145, 62, 62)
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.Text = "X"
closeButton.TextSize = 10
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Parent = top
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 6)
-- Keep the title clear of the close control.
title.Size = UDim2.new(1, -48, 1, 0)
connect(closeButton.Activated, shutdown)

print("[ARES v1.19] Native one-lap supervisor loaded. Native Moto Legends controller owns all bike inputs; no ARES key injection enabled.")
