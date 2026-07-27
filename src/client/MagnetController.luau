--!nonstrict
--[[
	MagnetController.luau

	Input, aim, and nothing else. The client's entire job is to answer "which
	hand, and roughly where was the player looking" — the server decides what
	that hits and what it does.

	One detail is load-bearing: the ray origin sent to the server is the
	*character's head*, not the camera. In third person the camera sits well
	behind the player, and MagnetService rejects any origin further than
	MagnetConfig.MaxOriginDeviation from the real head — that check is what stops
	a modified client from firing the magnet from an arbitrary point in the
	world. So the aim point is found with a camera ray locally, and then the
	direction is recomputed from the head toward it.

	Bindings: LMB / L2 / on-screen 왼손 = Pull, RMB / R2 / 오른손 = Push, matching
	the left-hand-pulls, right-hand-pushes fiction.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MagnetConfig = require(Shared.Config.MagnetConfig)
local Net = require(Shared.Net)

local MagnetController = {}

local AIM_DISTANCE = 400 -- how far the camera ray searches for something to aim at

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude
aimParams.IgnoreWater = true

local function getCharacterParts(): (Model?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	return character, head :: BasePart?
end

--- Where the player is aiming, in world space.
local function resolveAimPoint(character: Model): Vector3
	camera = workspace.CurrentCamera

	local origin: Vector3, direction: Vector3

	if UserInputService.MouseEnabled and not UserInputService.TouchEnabled then
		local mouseLocation = UserInputService:GetMouseLocation()
		local screenRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		origin, direction = screenRay.Origin, screenRay.Direction
	else
		-- Touch and gamepad aim from the middle of the screen.
		local viewport = camera.ViewportSize
		local screenRay = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
		origin, direction = screenRay.Origin, screenRay.Direction
	end

	aimParams.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(origin, direction * AIM_DISTANCE, aimParams)
	return if result then result.Position else origin + direction * AIM_DISTANCE
end

local function fire(action: string, phase: string)
	local character, head = getCharacterParts()
	if not character or not head then
		return
	end

	local origin = head.Position
	local aimPoint = resolveAimPoint(character)

	local delta = aimPoint - origin
	if delta.Magnitude < 0.1 then
		delta = camera.CFrame.LookVector
	end

	Net.MagnetAction:FireServer({
		action = action,
		phase = phase,
		origin = origin,
		direction = delta.Unit,
	})
end

--- Local cooldown mirror. Purely cosmetic — it keeps the UI honest and avoids
--- spamming the server with requests it would reject anyway. The real cooldown
--- is enforced server-side and this cannot shorten it.
local nextAllowed = { Pull = 0, Push = 0 }

--- Sources currently asking for the magnet to be held off — a menu that owns the
--- screen, a result card the cursor is resting on. Counted by source rather than
--- stored as one flag, so a card releasing its claim cannot re-arm the magnet
--- underneath an open panel.
local suppressors: { [string]: boolean } = {}
local suppressed = false

--- Which hands are currently held down, so suppression can release them. A Pull
--- held when the board opens is a live grapple on the server; dropping the
--- suppression without an End would leave the player flying while they read.
local held = { Pull = false, Push = false }

local function handleAction(action: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		if suppressed then
			-- Pass rather than Sink: the click belongs to the UI underneath.
			return Enum.ContextActionResult.Pass
		end

		local now = os.clock()
		if now < nextAllowed[action] then
			return Enum.ContextActionResult.Sink
		end
		nextAllowed[action] = now
			+ (if action == "Pull" then MagnetConfig.PullCooldown else MagnetConfig.PushCooldown)
		held[action] = true
		fire(action, "Begin")
	elseif inputState == Enum.UserInputState.End then
		if not held[action] then
			return Enum.ContextActionResult.Pass
		end
		held[action] = false
		fire(action, "End")
	end

	return Enum.ContextActionResult.Sink
end

--- Turns the magnet off while UI wants the click, and lets go of anything held.
--- @param source who is asking; the magnet stays off until every source releases
function MagnetController.SetSuppressed(source: string, value: boolean)
	suppressors[source] = value or nil

	local wanted = next(suppressors) ~= nil
	if suppressed == wanted then
		return
	end
	suppressed = wanted

	if not suppressed then
		return
	end

	for action, isHeld in held do
		if isHeld then
			held[action] = false
			fire(action, "End")
		end
	end
end

--- Remaining cooldown for a hand, 0..1, for the HUD to render.
function MagnetController.CooldownAlpha(action: string): number
	local remaining = nextAllowed[action] - os.clock()
	local total = if action == "Pull" then MagnetConfig.PullCooldown else MagnetConfig.PushCooldown
	if remaining <= 0 or total <= 0 then
		return 0
	end
	return math.clamp(remaining / total, 0, 1)
end

function MagnetController.Start()
	ContextActionService:BindAction("MagnetPull", function(_, inputState)
		return handleAction("Pull", inputState)
	end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonL2)

	ContextActionService:BindAction("MagnetPush", function(_, inputState)
		return handleAction("Push", inputState)
	end, true, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonR2)

	ContextActionService:SetTitle("MagnetPull", "왼손\nPULL")
	ContextActionService:SetTitle("MagnetPush", "오른손\nPUSH")
	ContextActionService:SetPosition("MagnetPull", UDim2.new(1, -180, 1, -140))
	ContextActionService:SetPosition("MagnetPush", UDim2.new(1, -100, 1, -200))

	-- Dropping the character mid-pull would otherwise leave the server holding a
	-- grapple that never gets released.
	player.CharacterRemoving:Connect(function()
		held.Pull = false
		held.Push = false
		fire("Pull", "End")
	end)
end

return MagnetController
