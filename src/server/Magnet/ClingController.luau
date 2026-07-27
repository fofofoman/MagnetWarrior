--!nonstrict
--[[
	ClingController.luau — 자석 벽 타기

	Holding Pull on a MagneticSurface drags the player in; once they arrive they
	latch on and can climb. Everything here runs on the server: the latch point,
	the climb speed and the release impulse are all server state, so the client
	cannot extend its reach, climb faster or launch harder than the config
	allows.

	The latch point is stored in the *surface's* object space and re-projected to
	world space every frame, which means a player riding a moving magnet wall
	(stage 7's timing puzzle) is carried along by it for free.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MagnetConfig = require(Shared.Config.MagnetConfig)
local Signal = require(Shared.Util.Signal)
local SoundKit = require(Shared.Util.SoundKit)
local Trove = require(Shared.Util.Trove)

local CLING_DISTANCE = 2.6 -- how far the torso floats off the surface
local EDGE_MARGIN = 1.5 -- keeps the latch point from sliding off the face
local ALIGN_RESPONSIVENESS = 45
local ALIGN_MAX_FORCE = 120000

local ClingController = {}

export type ClingState = {
	player: Player,
	surface: BasePart,
	localOffset: Vector3, -- latch point in surface object space
	localNormal: Vector3, -- outward face axis in surface object space
	startedAt: number,
	trove: any,
	align: AlignPosition,
	orient: AlignOrientation,
	humanoid: Humanoid,
	root: BasePart,
}

local states: { [Player]: ClingState } = {}
local heartbeat: RBXScriptConnection?

--- Fired whenever a cling ends, with (player, didLaunch). The bootstrap hooks
--- this into the movement audit so a legitimate wall launch is not flagged.
ClingController.Released = Signal.new()
ClingController.Engaged = Signal.new()

--- Returns the axis index (1..3) with the largest magnitude and its sign.
local function dominantAxis(vector: Vector3): (number, number)
	local ax, ay, az = math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)
	if ax >= ay and ax >= az then
		return 1, if vector.X >= 0 then 1 else -1
	elseif ay >= az then
		return 2, if vector.Y >= 0 then 1 else -1
	end
	return 3, if vector.Z >= 0 then 1 else -1
end

local function axisVector(axis: number, sign: number): Vector3
	if axis == 1 then
		return Vector3.new(sign, 0, 0)
	elseif axis == 2 then
		return Vector3.new(0, sign, 0)
	end
	return Vector3.new(0, 0, sign)
end

--- Snaps a point onto the chosen face of the part and keeps it inside the face
--- bounds, so climbing stops at the edge instead of drifting into the void.
local function clampToFace(surface: BasePart, localPoint: Vector3, normalAxis: number, normalSign: number): Vector3
	local half = surface.Size / 2
	local components = { localPoint.X, localPoint.Y, localPoint.Z }
	local halves = { half.X, half.Y, half.Z }

	for axis = 1, 3 do
		if axis == normalAxis then
			components[axis] = halves[axis] * normalSign
		else
			local limit = math.max(halves[axis] - EDGE_MARGIN, 0)
			components[axis] = math.clamp(components[axis], -limit, limit)
		end
	end

	return Vector3.new(components[1], components[2], components[3])
end

function ClingController.IsClinging(player: Player): boolean
	return states[player] ~= nil
end

function ClingController.GetSurface(player: Player): BasePart?
	local state = states[player]
	return state and state.surface
end

--- @param hitPosition world-space point on the surface the player latched to
--- @param worldNormal outward surface normal at that point
function ClingController.Engage(player: Player, surface: BasePart, hitPosition: Vector3, worldNormal: Vector3): boolean
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	-- Re-latching to the same surface should refresh rather than rebuild.
	local existing = states[player]
	if existing then
		if existing.surface == surface then
			return true
		end
		ClingController.Release(player, false)
	end

	local localNormalRaw = surface.CFrame:VectorToObjectSpace(worldNormal)
	local normalAxis, normalSign = dominantAxis(localNormalRaw)
	local localNormal = axisVector(normalAxis, normalSign)
	local localOffset =
		clampToFace(surface, surface.CFrame:PointToObjectSpace(hitPosition), normalAxis, normalSign)

	local trove = Trove.new()

	local rootAttachment = trove:Add(Instance.new("Attachment"))
	rootAttachment.Name = "MagnetClingAttachment"
	rootAttachment.Parent = root

	local align = trove:Add(Instance.new("AlignPosition"))
	align.Name = "MagnetCling"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = rootAttachment
	align.MaxForce = ALIGN_MAX_FORCE
	align.Responsiveness = ALIGN_RESPONSIVENESS
	align.RigidityEnabled = false
	align.Position = hitPosition + worldNormal * CLING_DISTANCE
	align.Parent = root

	local orient = trove:Add(Instance.new("AlignOrientation"))
	orient.Name = "MagnetClingOrientation"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = rootAttachment
	orient.MaxTorque = ALIGN_MAX_FORCE
	orient.Responsiveness = ALIGN_RESPONSIVENESS
	orient.RigidityEnabled = false
	orient.Parent = root

	-- AutoRotate is turned off so AlignOrientation owns facing, but the humanoid
	-- is deliberately left in a normal state: the climb reads
	-- `humanoid.MoveDirection` every frame, and PlatformStand would zero it.
	humanoid.AutoRotate = false

	local state: ClingState = {
		player = player,
		surface = surface,
		localOffset = localOffset,
		localNormal = localNormal,
		startedAt = os.clock(),
		trove = trove,
		align = align,
		orient = orient,
		humanoid = humanoid,
		root = root,
	}

	-- Losing the surface (destroyed, or its tag stripped mid-run) must not leave
	-- the player frozen in mid-air.
	trove:Add(surface.AncestryChanged:Connect(function(_, parent)
		if not parent then
			ClingController.Release(player, false)
		end
	end))
	trove:Add(humanoid.Died:Connect(function()
		ClingController.Release(player, false)
	end))

	states[player] = state
	SoundKit.PlayAt("ClingAttach", root)
	ClingController.Engaged:Fire(player, surface)
	return true
end

--- Drops everyone currently latched to a surface. MotionService calls this the
--- moment a wall's polarity dies — being carried by a wall that is no longer
--- magnetic would be the single most confusing thing in the timing stages.
function ClingController.ReleaseFromSurface(surface: BasePart, launch: boolean?)
	for player, state in states do
		if state.surface == surface then
			ClingController.Release(player, launch == true)
		end
	end
end

function ClingController.Release(player: Player, launch: boolean)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil

	state.trove:Clean()

	if state.humanoid and state.humanoid.Parent then
		state.humanoid.AutoRotate = true
	end

	if state.root and state.root.Parent then
		SoundKit.PlayAt(if launch then "GrappleLaunch" else "ClingRelease", state.root)
	end

	if launch and state.root and state.root.Parent then
		local worldNormal = state.surface.CFrame:VectorToWorldSpace(state.localNormal)
		local direction = (worldNormal + Vector3.new(0, 0.35, 0)).Unit

		-- Same rule as a push-off: a launch carries the speed you arrived with
		-- rather than resetting it, so riding a ferry into a wall kick is worth
		-- more than kicking off from a standstill.
		local speed = MagnetConfig.ChainSpeed(
			state.root.AssemblyLinearVelocity,
			direction,
			MagnetConfig.ClingReleaseImpulse,
			MagnetConfig.ClingLaunchChainBonus
		)

		state.root.AssemblyLinearVelocity = direction * speed
	end

	ClingController.Released:Fire(player, launch)
end

local function step(deltaTime: number)
	for player, state in states do
		local surface = state.surface
		local root = state.root
		local humanoid = state.humanoid

		if
			not surface.Parent
			or not root.Parent
			or not humanoid.Parent
			or humanoid.Health <= 0
			or player.Parent == nil
		then
			ClingController.Release(player, false)
			continue
		end

		if (os.clock() - state.startedAt) >= MagnetConfig.ClingMaxDuration then
			-- Overheat: you cannot park on a wall to skip a platforming section.
			ClingController.Release(player, true)
			continue
		end

		local worldNormal = surface.CFrame:VectorToWorldSpace(state.localNormal)

		-- MoveDirection comes from the client, but it only ever scales a
		-- server-owned climb speed, so the worst a modified client gets is
		-- perfect input — not extra distance.
		local moveDirection = humanoid.MoveDirection
		if moveDirection.Magnitude > 0.05 then
			local tangential = moveDirection - worldNormal * moveDirection:Dot(worldNormal)
			if tangential.Magnitude > 0.01 then
				local localMove = surface.CFrame:VectorToObjectSpace(tangential.Unit)
				local normalAxis, normalSign = dominantAxis(state.localNormal)
				state.localOffset = clampToFace(
					surface,
					state.localOffset + localMove * MagnetConfig.ClingMoveSpeed * deltaTime,
					normalAxis,
					normalSign
				)
			end
		end

		local worldPoint = surface.CFrame:PointToWorldSpace(state.localOffset)
		state.align.Position = worldPoint + worldNormal * CLING_DISTANCE
		state.orient.CFrame = CFrame.lookAt(Vector3.zero, -worldNormal, Vector3.yAxis)
	end
end

function ClingController.Start()
	if heartbeat then
		return
	end
	heartbeat = RunService.Heartbeat:Connect(step)

	Players.PlayerRemoving:Connect(function(player)
		ClingController.Release(player, false)
	end)
end

function ClingController.Stop()
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	for player in states do
		ClingController.Release(player, false)
	end
end

return ClingController
