--!nonstrict
--[[
	GhostPlayer.luau — 고스트 리플레이 재생

	Replays a recorded run as a translucent silhouette that starts the moment
	your own run does.

	Sync comes from RunState.Elapsed() — the same server-driven clock the HUD
	timer uses — rather than from a local stopwatch started on spawn. That means
	the ghost stays aligned with the *authoritative* run time even if the client
	stutters: if you fall behind, the ghost is genuinely ahead, which is the only
	way a race against a ghost means anything.

	Samples arrive at 10 Hz and are interpolated to the frame rate. Yaw is
	interpolated the short way around so a silhouette turning past 180° does not
	spin the wrong direction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local TimeFormat = require(Shared.Util.TimeFormat)
local Types = require(Shared.Types)

local RunState = require(script.Parent.Parent.State.RunState)

local GhostPlayer = {}

local VALUES_PER_SAMPLE = 4
local GHOST_COLOR = Color3.fromRGB(150, 210, 255)
local GHOST_TRANSPARENCY = 0.55

local player = Players.LocalPlayer

--- One loaded ghost per stage. Loading is explicit (the player asks for it in
--- the leaderboard panel) and persists until they load a different one.
local loaded: { [string]: Types.GhostPayload } = {}

local model: Model? = nil
local torso: BasePart? = nil
local head: BasePart? = nil
local activePayload: Types.GhostPayload? = nil

local function destroyModel()
	if model then
		model:Destroy()
	end
	model = nil
	torso = nil
	head = nil
	activePayload = nil
end

local function buildModel(payload: Types.GhostPayload)
	destroyModel()

	local container = Instance.new("Model")
	container.Name = "MagnetGhost"

	local body = Instance.new("Part")
	body.Name = "Torso"
	body.Size = Vector3.new(2, 3, 1)
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Material = Enum.Material.ForceField
	body.Color = GHOST_COLOR
	body.Transparency = GHOST_TRANSPARENCY
	body.Parent = container

	local headPart = Instance.new("Part")
	headPart.Name = "Head"
	headPart.Size = Vector3.new(1.4, 1.4, 1.4)
	headPart.Anchored = true
	headPart.CanCollide = false
	headPart.CanQuery = false
	headPart.CanTouch = false
	headPart.Material = Enum.Material.ForceField
	headPart.Color = GHOST_COLOR
	headPart.Transparency = GHOST_TRANSPARENCY
	headPart.Parent = container

	local label = Instance.new("BillboardGui")
	label.Name = "GhostLabel"
	label.Size = UDim2.fromOffset(180, 40)
	label.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	label.AlwaysOnTop = true
	label.Parent = body

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 13
	text.TextColor3 = GHOST_COLOR
	text.TextStrokeTransparency = 0.4
	text.Text = `{payload.displayName} · {TimeFormat.Short(payload.timeMs)}`
	text.Parent = label

	container.PrimaryPart = body
	container.Parent = workspace

	model = container
	torso = body
	head = headPart
	activePayload = payload
end

--- Shortest signed difference between two angles in degrees.
local function angleDelta(from: number, to: number): number
	return ((to - from + 180) % 360) - 180
end

--- Writes the silhouette's pose. Both parts are placed here rather than having
--- the head chase the torso through a property-changed signal, which would fire
--- every frame for no benefit.
local function pose(cframe: CFrame)
	if torso then
		torso.CFrame = cframe
	end
	if head then
		head.CFrame = cframe * CFrame.new(0, 2.2, 0)
	end
end

local function step()
	local payload = activePayload
	if not payload or not torso then
		return
	end

	local data = payload.data
	local count = math.floor(#data / VALUES_PER_SAMPLE)
	if count < 2 then
		return
	end

	local exact = (RunState.Elapsed() / 1000) * payload.sampleRate
	local index = math.floor(exact)

	if index >= count - 1 then
		-- Ghost has finished; park it on its final pose rather than vanishing,
		-- so you can see exactly where it beat you.
		local last = (count - 1) * VALUES_PER_SAMPLE
		pose(
			CFrame.new(data[last + 1] / 10, data[last + 2] / 10, data[last + 3] / 10)
				* CFrame.Angles(0, math.rad(data[last + 4]), 0)
		)
		return
	end

	local alpha = exact - index
	local a = index * VALUES_PER_SAMPLE
	local b = a + VALUES_PER_SAMPLE

	local from = Vector3.new(data[a + 1] / 10, data[a + 2] / 10, data[a + 3] / 10)
	local to = Vector3.new(data[b + 1] / 10, data[b + 2] / 10, data[b + 3] / 10)
	local yaw = data[a + 4] + angleDelta(data[a + 4], data[b + 4]) * alpha

	pose(CFrame.new(from:Lerp(to, alpha)) * CFrame.Angles(0, math.rad(yaw), 0))
end

local function onRunUpdate(update)
	if update.kind == "Started" then
		local payload = loaded[update.stageId]
		if payload and #payload.data >= VALUES_PER_SAMPLE * 2 then
			buildModel(payload)
		else
			destroyModel()
		end
	elseif update.kind == "Finished" or update.kind == "Aborted" then
		-- Leave the silhouette standing for a moment at its final pose.
		local expiring = model
		task.delay(4, function()
			if model == expiring then
				destroyModel()
			end
		end)
	end
end

--- Asks the server for a ghost and remembers it for the next run on that stage.
--- Returns the payload so the caller can surface `unavailableReason`.
function GhostPlayer.Request(stageId: string, scope: Types.GhostScope): Types.GhostPayload?
	local ok, payload = pcall(function()
		return Net.GetGhost:InvokeServer(stageId, scope)
	end)

	if not ok or typeof(payload) ~= "table" then
		return nil
	end

	if payload.unavailableReason then
		return payload
	end

	loaded[stageId] = payload
	return payload
end

function GhostPlayer.Clear(stageId: string)
	loaded[stageId] = nil
	if activePayload and activePayload.stageId == stageId then
		destroyModel()
	end
end

function GhostPlayer.LoadedFor(stageId: string): Types.GhostPayload?
	return loaded[stageId]
end

function GhostPlayer.Start()
	RunState.Changed:Connect(onRunUpdate)
	RunService.RenderStepped:Connect(step)

	player.CharacterRemoving:Connect(function()
		-- Dying ends the timed run; the ghost has nothing left to race.
		destroyModel()
	end)
end

return GhostPlayer
