--!nonstrict
--[[
	MagnetService.luau — the core mechanic, resolved entirely on the server.

	The client sends an *intent*: "I pressed Pull, my camera was here, pointing
	there." It does not send a target, a force, or a result. The server
	re-derives all of that:

	  1. rate limit          — token bucket, independent of the design cooldown
	  2. sanitise            — types, NaN/inf, sane magnitudes
	  3. authenticate origin — the claimed ray start must be near the real head
	  4. stage gate          — stage 1 is Pull-only because the server says so
	  5. cooldown            — server-tracked, not client-tracked
	  6. target resolution   — server raycast + server-side aim assist
	  7. force application   — server-owned physics (see MagneticRegistry)

	Failing any step returns a "Rejected"/"NoTarget" feedback event that the
	client may render, and nothing else happens. A modified client that skips
	steps 1-6 locally still lands here.

	The force splits two ways. Light objects fly (combat, puzzles). Anchored or
	heavy ones do not, so the reaction moves the *player* instead — that is
	traversal: pull yourself to a wall, cling, climb, push off.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MagnetConfig = require(Shared.Config.MagnetConfig)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)
local SoundKit = require(Shared.Util.SoundKit)
local StageConfig = require(Shared.Config.StageConfig)
local Trove = require(Shared.Util.Trove)

local ClingController = require(script.Parent.ClingController)
local MagneticRegistry = require(script.Parent.MagneticRegistry)

local MagnetService = {}

--- Injected by the bootstrap to avoid a require cycle with the run systems.
--- `GetActiveStageId` gates which hands a stage allows; `NoteBoost` tells the
--- movement audit that a burst of speed was legitimately earned.
local hooks = {
	GetActiveStageId = function(_player: Player): string?
		return nil
	end,
	NoteBoost = function(_player: Player, _reason: string) end,
}

function MagnetService.SetHooks(newHooks: { [string]: any })
	for key, value in newHooks do
		hooks[key] = value
	end
end

local actionLimiter = RateLimiter.new(MagnetConfig.MaxActionsPerSecond, MagnetConfig.RateLimitBurst)

type Cooldowns = { Pull: number, Push: number }
local cooldowns: { [Player]: Cooldowns } = {}

type GrappleState = {
	target: BasePart,
	localPoint: Vector3,
	startedAt: number,
	trove: any,
	velocity: LinearVelocity,
	root: BasePart,
}
local grapples: { [Player]: GrappleState } = {}

local heartbeat: RBXScriptConnection?

-- ─────────────────────────────────────────────────────────────────────────────
-- Validation helpers
-- ─────────────────────────────────────────────────────────────────────────────

local MAX_COORDINATE = 1e6

local function isSaneVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	-- NaN fails every comparison with itself; inf fails the magnitude bound.
	if value.X ~= value.X or value.Y ~= value.Y or value.Z ~= value.Z then
		return false
	end
	return math.abs(value.X) < MAX_COORDINATE
		and math.abs(value.Y) < MAX_COORDINATE
		and math.abs(value.Z) < MAX_COORDINATE
end

local function getAliveCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil, nil, nil
	end

	return character, humanoid, root
end

--- Magnet audio is positional and server-played rather than local to the actor.
--- Costs one round trip of latency, but it means every player hears every
--- magnet in the room, and it matches the beam VFX — which is also drawn from
--- the server's answer rather than from the local key press.
local function playActionSound(player: Player, action: string, outcome: string)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	if outcome == "Rejected" or outcome == "OnCooldown" then
		SoundKit.PlayAt("MagnetDenied", root)
	elseif outcome == "NoTarget" then
		SoundKit.PlayAt("MagnetMiss", root)
	elseif outcome == "MovedTarget" or outcome == "MovedSelf" then
		SoundKit.PlayAt(if action == "Pull" then "PullFire" else "PushFire", root)
	end
end

local function feedback(player: Player, action: string, outcome: string, target: BasePart?, hitPosition: Vector3?)
	playActionSound(player, action, outcome)

	local payload = {
		actor = player,
		action = action,
		outcome = outcome,
		target = target,
		hitPosition = hitPosition,
	}

	if outcome == "Rejected" or outcome == "NoTarget" or outcome == "OnCooldown" then
		-- Failures are private: broadcasting them would just be noise.
		Net.MagnetFeedback:FireClient(player, payload)
	else
		-- Successes are public so other players see the beam.
		Net.MagnetFeedback:FireAllClients(payload)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Target resolution
-- ─────────────────────────────────────────────────────────────────────────────

local function buildRaycastParams(character: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	return params
end

--- Aim assist, run on the server so it cannot be inflated by the client. The
--- cone maths is cheap; the line-of-sight raycasts are not, so only the best
--- few candidates by angle are actually tested.
local function coneAssist(origin: Vector3, direction: Vector3, params: RaycastParams): (BasePart?, Vector3?, Vector3?)
	local cosLimit = math.cos(math.rad(MagnetConfig.AssistConeDegrees))

	type Candidate = { part: BasePart, cosine: number, distance: number }
	local candidates: { Candidate } = {}

	for part in MagneticRegistry.All() do
		if not part.Parent then
			continue
		end

		local delta = part.Position - origin
		local distance = delta.Magnitude
		if distance < 0.1 or distance > MagnetConfig.MaxRange then
			continue
		end

		local cosine = delta.Unit:Dot(direction)
		if cosine < cosLimit then
			continue
		end

		table.insert(candidates, { part = part, cosine = cosine, distance = distance })
	end

	table.sort(candidates, function(a, b)
		return a.cosine > b.cosine
	end)

	local tested = 0
	for _, candidate in candidates do
		tested += 1
		if tested > MagnetConfig.AssistMaxCandidates then
			break
		end

		local delta = candidate.part.Position - origin
		local result = workspace:Raycast(origin, delta, params)

		if result == nil then
			-- Origin is effectively inside the part; treat it as a hit.
			return candidate.part, candidate.part.Position, (origin - candidate.part.Position).Unit
		end
		if result.Instance == candidate.part then
			return candidate.part, result.Position, result.Normal
		end
		-- Anything else in the way means the candidate is occluded; keep going.
	end

	return nil, nil, nil
end

local function resolveTarget(character: Model, origin: Vector3, direction: Vector3): (BasePart?, Vector3?, Vector3?)
	local params = buildRaycastParams(character)

	local result = workspace:Raycast(origin, direction * MagnetConfig.MaxRange, params)
	if result and MagneticRegistry.IsMagnetic(result.Instance) then
		return result.Instance :: BasePart, result.Position, result.Normal
	end

	return coneAssist(origin, direction, params)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Force application
-- ─────────────────────────────────────────────────────────────────────────────

local function distanceFalloff(distance: number): number
	local t = math.clamp(distance / MagnetConfig.MaxRange, 0, 1)
	return 1 - (1 - MagnetConfig.FalloffAtMaxRange) * t
end

local function applyToObject(
	player: Player,
	root: BasePart,
	part: BasePart,
	action: string,
	origin: Vector3,
	distance: number
)
	local mass = part.AssemblyMass
	if mass <= 0 then
		return
	end

	local desiredVelocity: Vector3

	if action == "Pull" then
		local holdPoint = root.Position
			+ root.CFrame.LookVector * MagnetConfig.HoldDistance
			+ Vector3.new(0, MagnetConfig.HoldHeight, 0)
		local toHold = holdPoint - part.Position
		local holdDistance = toHold.Magnitude

		if holdDistance < 0.1 then
			return
		end

		local speed = math.clamp(
			holdDistance * MagnetConfig.PullTargetGain,
			MagnetConfig.PullTargetMinSpeed,
			MagnetConfig.PullTargetMaxSpeed
		)
		desiredVelocity = toHold.Unit * speed
	else
		local away = part.Position - origin
		local awayDirection = if away.Magnitude > 0.1 then away.Unit else root.CFrame.LookVector
		desiredVelocity = (awayDirection + Vector3.new(0, MagnetConfig.PushTargetUpBias, 0)).Unit
			* MagnetConfig.PushTargetSpeed
	end

	-- Impulse = mass * velocity change, then clamped. The clamp is what makes
	-- weight matter: a heavy block gets the same newtons as a light one and
	-- therefore moves less.
	local impulse = (desiredVelocity - part.AssemblyLinearVelocity) * mass
	local ceiling = (if action == "Pull" then MagnetConfig.PullImpulse else MagnetConfig.PushImpulse)
		* distanceFalloff(distance)

	if impulse.Magnitude > ceiling then
		impulse = impulse.Unit * ceiling
	end

	part:ApplyImpulse(impulse)
	MagneticRegistry.MarkImpulsed(part, player)
end

local function stopGrapple(player: Player)
	local state = grapples[player]
	if not state then
		return
	end
	grapples[player] = nil
	state.trove:Clean()
end

local function startGrapple(player: Player, root: BasePart, target: BasePart, hitPosition: Vector3)
	stopGrapple(player)

	local trove = Trove.new()

	local attachment = trove:Add(Instance.new("Attachment"))
	attachment.Name = "MagnetGrappleAttachment"
	attachment.Parent = root

	local velocity = trove:Add(Instance.new("LinearVelocity"))
	velocity.Name = "MagnetGrapple"
	velocity.Attachment0 = attachment
	velocity.MaxForce = MagnetConfig.SelfPullMaxForce
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root

	grapples[player] = {
		target = target,
		localPoint = target.CFrame:PointToObjectSpace(hitPosition),
		startedAt = os.clock(),
		trove = trove,
		velocity = velocity,
		root = root,
	}

	hooks.NoteBoost(player, "grapple")
end

local function stepGrapples()
	for player, state in grapples do
		local target = state.target
		local root = state.root

		if not target.Parent or not root.Parent or player.Parent == nil then
			stopGrapple(player)
			continue
		end

		if (os.clock() - state.startedAt) >= MagnetConfig.SelfPullMaxDuration then
			stopGrapple(player)
			continue
		end

		-- Recomputed from the target's current CFrame, so grappling a moving
		-- magnet wall tracks it.
		local worldPoint = target.CFrame:PointToWorldSpace(state.localPoint)
		local delta = worldPoint - root.Position
		local distance = delta.Magnitude

		if distance <= MagnetConfig.ClingRange then
			local info = MagneticRegistry.Get(target)
			if info and info.isSurface then
				local normal = (root.Position - worldPoint)
				local normalUnit = if normal.Magnitude > 0.01 then normal.Unit else Vector3.yAxis
				ClingController.Engage(player, target, worldPoint, normalUnit)
			end
			stopGrapple(player)
			continue
		end

		state.velocity.VectorVelocity = delta.Unit * MagnetConfig.SelfPullSpeed
		hooks.NoteBoost(player, "grapple")
	end
end

local function pushSelfOff(player: Player, root: BasePart, hitPosition: Vector3)
	local away = root.Position - hitPosition
	local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.yAxis
	local biased = (direction + Vector3.new(0, MagnetConfig.SelfPushUpBias, 0)).Unit

	root.AssemblyLinearVelocity = biased * MagnetConfig.SelfPushSpeed
	hooks.NoteBoost(player, "pushoff")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote handler
-- ─────────────────────────────────────────────────────────────────────────────

local function getCooldowns(player: Player): Cooldowns
	local entry = cooldowns[player]
	if not entry then
		entry = { Pull = 0, Push = 0 }
		cooldowns[player] = entry
	end
	return entry
end

local function onMagnetAction(player: Player, payload: any)
	if not actionLimiter:Consume(player) then
		return -- Silently throttled: replying would just confirm the limit to a probe.
	end

	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.action
	if action ~= "Pull" and action ~= "Push" then
		return
	end

	local phase = payload.phase
	if phase ~= "Begin" and phase ~= "End" then
		return
	end

	local character, _humanoid, root = getAliveCharacter(player)
	if not character or not root then
		return
	end

	-- Releasing Pull drops any cling or grapple. No further validation needed:
	-- letting go is always allowed.
	if phase == "End" then
		if action == "Pull" then
			stopGrapple(player)
			if ClingController.IsClinging(player) then
				ClingController.Release(player, false)
				feedback(player, action, "Released")
			end
		end
		return
	end

	local stageId = hooks.GetActiveStageId(player)
	if stageId and not StageConfig.IsActionAllowed(stageId, action) then
		feedback(player, action, "Rejected")
		return
	end

	if not isSaneVector(payload.origin) or not isSaneVector(payload.direction) then
		feedback(player, action, "Rejected")
		return
	end

	local origin = payload.origin :: Vector3
	local direction = payload.direction :: Vector3

	local directionLength = direction.Magnitude
	if directionLength < 0.9 or directionLength > 1.1 then
		feedback(player, action, "Rejected")
		return
	end
	direction = direction.Unit

	-- The claimed ray must start near the player's actual head. This is what
	-- stops a client from firing the magnet across the map from a made-up
	-- position.
	local head = character:FindFirstChild("Head") :: BasePart?
	local anchorPosition = if head then head.Position else root.Position
	if (origin - anchorPosition).Magnitude > MagnetConfig.MaxOriginDeviation then
		feedback(player, action, "Rejected")
		return
	end

	local now = os.clock()
	local playerCooldowns = getCooldowns(player)
	if now < playerCooldowns[action] then
		feedback(player, action, "OnCooldown")
		return
	end

	-- Pushing while latched to a wall always means "launch me off it", even if
	-- there is nothing else in front of the player.
	if action == "Push" and ClingController.IsClinging(player) then
		local surface = ClingController.GetSurface(player)
		playerCooldowns.Push = now + MagnetConfig.PushCooldown
		ClingController.Release(player, true)
		hooks.NoteBoost(player, "clinglaunch")
		feedback(player, action, "MovedSelf", surface)
		return
	end

	local target, hitPosition, _normal = resolveTarget(character, origin, direction)
	if not target or not hitPosition then
		feedback(player, action, "NoTarget")
		return
	end

	local distance = (hitPosition - origin).Magnitude
	playerCooldowns[action] = now + (if action == "Pull" then MagnetConfig.PullCooldown else MagnetConfig.PushCooldown)

	if MagneticRegistry.IsImmovable(target) then
		if distance < MagnetConfig.MinRange and action == "Pull" then
			-- Already touching it; there is nothing to close.
			feedback(player, action, "NoTarget", target, hitPosition)
			return
		end

		if action == "Pull" then
			startGrapple(player, root, target, hitPosition)
			feedback(player, action, "MovedSelf", target, hitPosition)
		else
			pushSelfOff(player, root, hitPosition)
			feedback(player, action, "MovedSelf", target, hitPosition)
		end
		return
	end

	applyToObject(player, root, target, action, origin, distance)
	feedback(player, action, "MovedTarget", target, hitPosition)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

local function releasePlayer(player: Player)
	stopGrapple(player)
	ClingController.Release(player, false)
	cooldowns[player] = nil
	actionLimiter:Release(player)
end

--- Called by the run systems when a run ends or the player is teleported, so a
--- grapple cannot survive across a reset.
function MagnetService.ClearPlayerState(player: Player)
	stopGrapple(player)
	ClingController.Release(player, false)
end

function MagnetService.Start()
	MagneticRegistry.Start()
	ClingController.Start()

	Net.MagnetAction.OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(onMagnetAction, player, payload)
		if not ok and GameConfig.Debug.MagnetResolution then
			warn(`[MagnetService] handler error for {player.Name}: {err}`)
		end
	end)

	Players.PlayerRemoving:Connect(releasePlayer)

	-- A character being removed (death, respawn, teleport) must not leave a
	-- grapple or cling attached to a body that no longer exists.
	local function watchCharacter(player: Player)
		player.CharacterRemoving:Connect(function()
			MagnetService.ClearPlayerState(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end
	Players.PlayerAdded:Connect(watchCharacter)

	heartbeat = RunService.Heartbeat:Connect(stepGrapples)

	ClingController.Released:Connect(function(player: Player, launched: boolean)
		if launched then
			hooks.NoteBoost(player, "clinglaunch")
		end
	end)
end

return MagnetService
