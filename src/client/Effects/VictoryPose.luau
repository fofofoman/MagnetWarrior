--!nonstrict
--[[
	VictoryPose.luau — 승리 포즈

	The 승리 포즈 팩 was the one product in the shop that sold nothing. The pass
	existed, the four options were listed, the server validated ownership and
	published the choice to the player's `Pose` attribute — and no code anywhere
	read that attribute. Someone could buy it, pick "Salute", clear a stage and
	see exactly what a player who owned nothing saw.

	This renders it. Every pose is built out of primitives at runtime for the same
	reason the stages are: uploading an animation is a creator-dashboard step this
	repository cannot take, and a cosmetic that waits on an asset id is a cosmetic
	that does not exist. `animationId` is left as a slot on each pose so a real
	animation can be layered on later exactly the way SoundKit takes asset ids —
	the effect plays either way.

	Driven by a server broadcast rather than by the local run state, so a victory
	pose is something the room sees. The `Pose` attribute already replicates, so
	the broadcast only has to say *who* finished; every client resolves what to
	draw from the attribute it can already read.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local VictoryPose = {}

local DURATION = 2.4

type PoseStyle = {
	color: Color3,
	--- Uploaded animation for this pose, or 0 while there is none. The procedural
	--- effect below is not a placeholder for it — they are meant to stack.
	animationId: number,
	build: (root: BasePart, color: Color3) -> (),
}

local function makeAnchor(root: BasePart, cframe: CFrame, lifetime: number): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.CFrame = cframe
	part.Parent = workspace
	Debris:AddItem(part, lifetime)
	return part
end

--- A flat ring on the ground under the character. Cylinder parts stand on their
--- X axis, so the 90° roll is what lays one down.
local function groundRing(root: BasePart, color: Color3, startSize: number, endSize: number, seconds: number)
	local ring = makeAnchor(root, CFrame.new(root.Position - Vector3.new(0, 2.6, 0)) * CFrame.Angles(0, 0, math.rad(90)), seconds + 0.3)
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, startSize, startSize)
	ring.Color = color
	ring.Transparency = 0.15

	TweenService:Create(ring, TweenInfo.new(seconds, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, endSize, endSize),
		Transparency = 1,
	}):Play()
end

local function column(root: BasePart, color: Color3, width: number, seconds: number)
	local beam = makeAnchor(root, CFrame.new(root.Position + Vector3.new(0, 8, 0)), seconds + 0.3)
	beam.Size = Vector3.new(width, 22, width)
	beam.Color = color
	beam.Transparency = 0.4

	TweenService:Create(beam, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(width * 0.1, 34, width * 0.1),
		Transparency = 1,
	}):Play()
end

local function sparks(root: BasePart, color: Color3, count: number, speed: NumberRange, upward: boolean)
	local anchor = makeAnchor(root, CFrame.new(root.Position), DURATION + 0.6)
	anchor.Size = Vector3.one
	anchor.Transparency = 1

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.9
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = speed
	emitter.Lifetime = NumberRange.new(0.6, 1.3)
	emitter.SpreadAngle = if upward then Vector2.new(25, 25) else Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, if upward then 12 else -28, 0)
	emitter.Drag = 2
	emitter.Rate = 0
	emitter.Parent = attachment

	emitter:Emit(count)
end

--- An orbiting ring, tilted so it reads as a band around the character rather
--- than a disc under them. Two of these in opposing colours is the Polarity pose.
local function orbit(root: BasePart, color: Color3, radius: number, tilt: number, direction: number)
	local ring = makeAnchor(root, CFrame.new(root.Position), DURATION + 0.3)
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.35, radius, radius)
	ring.Color = color
	ring.Transparency = 0.2

	local spin = TweenService:Create(ring, TweenInfo.new(DURATION, Enum.EasingStyle.Linear), {
		Transparency = 1,
		Size = Vector3.new(0.35, radius * 1.6, radius * 1.6),
	})
	spin:Play()

	-- Driven off the tween's own clock rather than a heartbeat connection, so the
	-- effect owns its whole lifetime and cannot outlive itself.
	task.spawn(function()
		local started = os.clock()
		while ring.Parent and (os.clock() - started) < DURATION do
			local angle = (os.clock() - started) * direction * 4
			ring.CFrame = CFrame.new(root.Position)
				* CFrame.Angles(0, angle, 0)
				* CFrame.Angles(0, 0, math.rad(90) + tilt)
			task.wait()
		end
	end)
end

local styles: { [string]: PoseStyle } = {
	Salute = {
		color = Color3.fromRGB(255, 205, 84),
		animationId = 0,
		build = function(root, color)
			column(root, color, 5, 1.1)
			sparks(root, color, 40, NumberRange.new(14, 26), true)
			groundRing(root, color, 6, 26, 0.9)
		end,
	},
	Hover = {
		color = Color3.fromRGB(96, 200, 255),
		animationId = 0,
		build = function(root, color)
			groundRing(root, color, 5, 16, 1.4)
			groundRing(root, color, 3, 11, 2.0)
			sparks(root, color, 26, NumberRange.new(6, 14), true)
		end,
	},
	Crush = {
		color = Color3.fromRGB(255, 96, 88),
		animationId = 0,
		build = function(root, color)
			-- One hard slam: a fast wide ring and a heavy scatter, no lingering.
			groundRing(root, color, 4, 44, 0.55)
			groundRing(root, color, 4, 30, 0.85)
			sparks(root, color, 55, NumberRange.new(26, 48), false)
		end,
	},
	Polarity = {
		color = Color3.fromRGB(186, 120, 255),
		animationId = 0,
		build = function(root, _color)
			-- The two hands, orbiting in opposite directions.
			orbit(root, Color3.fromRGB(64, 156, 255), 9, 0.35, 1)
			orbit(root, Color3.fromRGB(255, 96, 88), 7, -0.35, -1)
			sparks(root, Color3.fromRGB(186, 120, 255), 30, NumberRange.new(10, 20), true)
		end,
	},
}

VictoryPose.Styles = styles

local function play(actor: Player)
	local character = actor.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local name = actor:GetAttribute("Pose")
	local style = if typeof(name) == "string" then styles[name] else nil
	if not style then
		return -- "None", or a value this client does not know how to draw
	end

	style.build(root, style.color)

	-- Layered on top of the effect when an animation exists; the effect is the
	-- part that always plays.
	if style.animationId ~= 0 then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local animation = Instance.new("Animation")
			animation.AnimationId = `rbxassetid://{style.animationId}`
			local ok, track = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			if ok and track then
				track:Play()
				Debris:AddItem(animation, DURATION)
			end
		end
	end
end

function VictoryPose.Start()
	Net.CombatFeedback.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or payload.kind ~= "VictoryPose" then
			return
		end
		local actor = payload.actor
		if typeof(actor) ~= "Instance" or not actor:IsA("Player") then
			return
		end
		local ok, err = pcall(play, actor)
		if not ok then
			warn(`[VictoryPose] {err}`)
		end
	end)
end

return VictoryPose
