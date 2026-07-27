--!nonstrict
--[[
	ImpactEffects.luau

	Particle bursts and camera shake for everything CombatService announces.

	The server sends one small event per impact — kind, position, magnitude,
	colour — rather than each client inferring impacts from physics. That keeps
	what you see tied to what actually did damage: if the server did not count
	it, nothing sparks, and a hit that looked weak but registered still reads as
	a hit.

	Shake falls off with distance and is capped, because this is a platformer
	with a precise magnet and an uncontrollable camera would cost more than the
	feedback is worth.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local ImpactEffects = {}

local SHAKE_RANGE = 120 -- studs beyond which an impact is not felt
local SHAKE_MAX_OFFSET = 1.4 -- studs
local SHAKE_MAX_ANGLE = 0.02 -- radians
local SHAKE_DECAY = 5.5 -- per second
local SHAKE_CAP = 1 -- never let stacked impacts exceed one full shake

local player = Players.LocalPlayer

local shake = 0

type BurstStyle = {
	count: number,
	speed: NumberRange,
	size: number,
	lifetime: NumberRange,
	shake: number,
	spread: number,
}

local styles: { [string]: BurstStyle } = {
	Impact = {
		count = 18,
		speed = NumberRange.new(14, 30),
		size = 1.4,
		lifetime = NumberRange.new(0.25, 0.5),
		shake = 0.5,
		spread = 180,
	},
	PlayerHurt = {
		count = 12,
		speed = NumberRange.new(8, 18),
		size = 1.1,
		lifetime = NumberRange.new(0.2, 0.4),
		shake = 0.8,
		spread = 180,
	},
	EnemyDeath = {
		count = 34,
		speed = NumberRange.new(20, 44),
		size = 1.8,
		lifetime = NumberRange.new(0.35, 0.7),
		shake = 0.45,
		spread = 360,
	},
	BossArmorOpen = {
		count = 44,
		speed = NumberRange.new(24, 40),
		size = 2.4,
		lifetime = NumberRange.new(0.5, 0.9),
		shake = 0.7,
		spread = 360,
	},
	BossArmorClose = {
		count = 20,
		speed = NumberRange.new(10, 20),
		size = 1.8,
		lifetime = NumberRange.new(0.3, 0.6),
		shake = 0.4,
		spread = 360,
	},
	BossDefeated = {
		count = 90,
		speed = NumberRange.new(30, 70),
		size = 3.2,
		lifetime = NumberRange.new(0.8, 1.6),
		shake = 1,
		spread = 360,
	},
}

local function burst(kind: string, position: Vector3, magnitude: number, color: Color3?)
	local style = styles[kind]
	if not style then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "ImpactBurst"
	anchor.Size = Vector3.one
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Position = position
	anchor.Parent = workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local tint = color or Color3.fromRGB(255, 214, 150)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(tint)
	emitter.LightEmission = 0.8
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, style.size * (0.6 + magnitude * 0.6)),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = style.speed
	emitter.Lifetime = style.lifetime
	emitter.SpreadAngle = Vector2.new(style.spread, style.spread)
	emitter.Rate = 0
	emitter.Drag = 3
	emitter.Acceleration = Vector3.new(0, -40, 0)
	emitter.Parent = attachment

	emitter:Emit(math.floor(style.count * (0.5 + magnitude * 0.5)))

	-- Emit is instant but the particles outlive it, so the anchor has to stick
	-- around past the longest lifetime.
	Debris:AddItem(anchor, style.lifetime.Max + 0.5)

	-- Shake only for impacts the local player could plausibly feel.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local distance = (root.Position - position).Magnitude
	if distance > SHAKE_RANGE then
		return
	end

	local falloff = 1 - (distance / SHAKE_RANGE)
	shake = math.min(SHAKE_CAP, shake + style.shake * magnitude * falloff * falloff)
end

local function onCombatFeedback(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.position) ~= "Vector3" or typeof(payload.kind) ~= "string" then
		return
	end

	local magnitude = payload.magnitude
	burst(
		payload.kind,
		payload.position,
		if typeof(magnitude) == "number" then math.clamp(magnitude, 0, 1) else 0.5,
		if typeof(payload.color) == "Color3" then payload.color else nil
	)
end

local function stepShake(deltaTime: number)
	if shake <= 0.001 then
		shake = 0
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local amount = shake
	local offset = Vector3.new(
		(math.random() * 2 - 1) * SHAKE_MAX_OFFSET,
		(math.random() * 2 - 1) * SHAKE_MAX_OFFSET,
		(math.random() * 2 - 1) * SHAKE_MAX_OFFSET
	) * amount

	local tilt = (math.random() * 2 - 1) * SHAKE_MAX_ANGLE * amount

	camera.CFrame = camera.CFrame * CFrame.new(offset) * CFrame.Angles(0, 0, tilt)

	shake = math.max(0, shake - SHAKE_DECAY * deltaTime * math.max(shake, 0.25))
end

function ImpactEffects.Start()
	Net.CombatFeedback.OnClientEvent:Connect(function(payload)
		local ok, err = pcall(onCombatFeedback, payload)
		if not ok then
			warn(`[ImpactEffects] {err}`)
		end
	end)

	-- After the default camera has written its CFrame for the frame, so the
	-- shake is applied on top rather than being overwritten.
	RunService:BindToRenderStep("MagnetWarriorShake", Enum.RenderPriority.Camera.Value + 1, stepShake)
end

return ImpactEffects
