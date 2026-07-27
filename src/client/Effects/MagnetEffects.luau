--!nonstrict
--[[
	MagnetEffects.luau

	Draws the magnet: a beam from the acting player's hand to whatever the server
	said they hit, plus the movement trail cosmetic.

	Effects are driven by the *server's* feedback event, not by local input. That
	means what you see is what actually happened — if the server rejected the
	action or found no target, no beam appears, and the feedback loop stays
	honest. It also means other players' magnets are visible, since successes are
	broadcast.

	Beam colour comes from the actor's `BeamColor` attribute, which
	MonetizationService sets after validating ownership. Attributes replicate on
	their own, so no extra remote is needed to see someone else's cosmetics.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Theme = require(script.Parent.Parent.UI.Theme)

local MagnetEffects = {}

local BEAM_LIFETIME = 0.3
local TRAIL_SPEED_THRESHOLD = 48 -- studs/s before the trail switches on

local localPlayer = Players.LocalPlayer

local function beamColorFor(actor: Player, action: string): Color3
	local name = actor:GetAttribute("BeamColor")
	local base = Theme.BeamColors[if typeof(name) == "string" then name else "Default"]
		or Theme.BeamColors.Default

	if action == "Push" then
		-- Push reads warmer so the two hands are distinguishable at a glance,
		-- even when they share a cosmetic colour.
		return base:Lerp(Color3.fromRGB(255, 140, 90), 0.45)
	end
	return base
end

local function handAttachment(character: Model, action: string): Attachment?
	local handName = if action == "Pull" then "LeftHand" else "RightHand"
	local armName = if action == "Pull" then "Left Arm" else "Right Arm"

	local limb = character:FindFirstChild(handName)
		or character:FindFirstChild(armName)
		or character:FindFirstChild("HumanoidRootPart")

	if not limb or not limb:IsA("BasePart") then
		return nil
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "MagnetBeamOrigin"
	attachment.Parent = limb
	return attachment
end

local function drawBeam(actor: Player, action: string, target: BasePart?, hitPosition: Vector3?)
	local character = actor.Character
	if not character then
		return
	end

	local originAttachment = handAttachment(character, action)
	if not originAttachment then
		return
	end

	-- Anchor the far end to the target if there is one, so the beam tracks a
	-- crate as it flies rather than pointing at where it used to be.
	local endPart: BasePart
	local endAttachment = Instance.new("Attachment")

	if target and target.Parent then
		endPart = target
		endAttachment.WorldPosition = hitPosition or target.Position
		endAttachment.Parent = target
	else
		local marker = Instance.new("Part")
		marker.Name = "MagnetBeamAnchor"
		marker.Size = Vector3.one
		marker.Transparency = 1
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Position = hitPosition or character:GetPivot().Position
		marker.Parent = workspace
		endPart = marker
		endAttachment.Parent = marker
		Debris:AddItem(marker, BEAM_LIFETIME + 0.1)
	end

	local color = beamColorFor(actor, action)

	local beam = Instance.new("Beam")
	beam.Attachment0 = originAttachment
	beam.Attachment1 = endAttachment
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Width0 = if action == "Pull" then 0.55 else 0.9
	beam.Width1 = if action == "Pull" then 0.2 else 0.45
	beam.FaceCamera = true
	-- Pull arcs inward, push snaps out straight.
	beam.CurveSize0 = if action == "Pull" then 6 else 0
	beam.CurveSize1 = if action == "Pull" then -6 else 0
	beam.Transparency = NumberSequence.new(0.1)
	beam.Parent = originAttachment

	TweenService:Create(beam, TweenInfo.new(BEAM_LIFETIME), {
		Transparency = NumberSequence.new(1),
	}):Play()

	task.delay(BEAM_LIFETIME + 0.05, function()
		beam:Destroy()
		originAttachment:Destroy()
		if endPart == target then
			endAttachment:Destroy()
		end
	end)
end

local function onFeedback(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local actor = payload.actor
	if typeof(actor) ~= "Instance" or not actor:IsA("Player") then
		return
	end

	local outcome = payload.outcome
	if outcome ~= "MovedTarget" and outcome ~= "MovedSelf" then
		return -- rejections and misses draw nothing, on purpose
	end

	drawBeam(actor, payload.action, payload.target, payload.hitPosition)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Movement trail cosmetic
-- ─────────────────────────────────────────────────────────────────────────────

local trailPresets = {
	Sparks = { color = Color3.fromRGB(255, 196, 76), lifetime = 0.35 },
	Ion = { color = Color3.fromRGB(96, 200, 255), lifetime = 0.5 },
	Magnetite = { color = Color3.fromRGB(180, 180, 200), lifetime = 0.4 },
	Aurora = { color = Color3.fromRGB(150, 255, 200), lifetime = 0.6 },
}

local function setupTrail(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root then
		return
	end

	local top = Instance.new("Attachment")
	top.Name = "TrailTop"
	top.Position = Vector3.new(0, 1.2, 0)
	top.Parent = root

	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailBottom"
	bottom.Position = Vector3.new(0, -1.2, 0)
	bottom.Parent = root

	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Enabled = false
	trail.LightEmission = 0.8
	trail.Parent = root

	local function refresh()
		local name = localPlayer:GetAttribute("Trail")
		local preset = trailPresets[if typeof(name) == "string" then name else ""]
		if not preset then
			trail.Enabled = false
			trail.Lifetime = 0.3
			return
		end
		trail.Color = ColorSequence.new(preset.color)
		trail.Lifetime = preset.lifetime
	end

	refresh()
	localPlayer:GetAttributeChangedSignal("Trail"):Connect(refresh)

	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent then
			connection:Disconnect()
			return
		end
		local name = localPlayer:GetAttribute("Trail")
		local hasTrail = typeof(name) == "string" and trailPresets[name] ~= nil
		trail.Enabled = hasTrail and root.AssemblyLinearVelocity.Magnitude >= TRAIL_SPEED_THRESHOLD
	end)
end

function MagnetEffects.Start()
	Net.MagnetFeedback.OnClientEvent:Connect(function(payload)
		local ok, err = pcall(onFeedback, payload)
		if not ok then
			warn(`[MagnetEffects] {err}`)
		end
	end)

	if localPlayer.Character then
		task.spawn(setupTrail, localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(setupTrail)
end

return MagnetEffects
