--!nonstrict
--[[
	CombatService.luau — 벽에 처박으면 데미지

	Impact damage for anything the magnet threw. Three rules make it read as a
	mechanic rather than as random chip damage:

	1. **Only thrown objects hurt.** MagneticRegistry.IsThrown gates everything,
	   so a crate rolling downhill is scenery, while the same crate two seconds
	   after a Push is a weapon.

	2. **Speed is the damage.** Below MagnetConfig.ImpactMinSpeed nothing
	   happens at all. This is what makes "slam it into the wall" the correct
	   play instead of "nudge it repeatedly".

	3. **Velocity is sampled before the collision, not after.** Touched fires
	   once the physics step has already resolved and reflected the velocity, so
	   reading it there under-reports every hit — sometimes to zero. A rolling
	   cache of pre-collision velocities fixes that, and it is the difference
	   between the mechanic feeling crisp and feeling broken.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MagnetConfig = require(Shared.Config.MagnetConfig)
local Net = require(Shared.Net)
local SoundKit = require(Shared.Util.SoundKit)

local EnemyService = require(script.Parent.EnemyService)
local MagneticRegistry = require(script.Parent.Parent.Magnet.MagneticRegistry)

local CombatService = {}

--- Impacts above this share of ImpactMaxDamage read as "heavy" and get the
--- bigger sound and burst.
local HEAVY_IMPACT_SHARE = 0.45

--- Announces an impact so clients can spawn particles and shake the camera.
--- Broadcast rather than sent to the thrower alone: a crate hitting a wall is a
--- world event, and everyone nearby should see it.
local function announceImpact(kind: string, position: Vector3, damage: number, color: Color3?)
	Net.CombatFeedback:FireAllClients({
		kind = kind,
		position = position,
		magnitude = math.clamp(damage / MagnetConfig.ImpactMaxDamage, 0, 1),
		color = color,
	})
end

CombatService.AnnounceImpact = announceImpact

--- How long a sampled velocity stays usable, in seconds.
local VELOCITY_SAMPLE_TTL = 0.25

type Sample = { velocity: Vector3, at: number }
local samples: { [BasePart]: Sample } = {}
local connections: { [BasePart]: RBXScriptConnection } = {}

local function recordedVelocity(part: BasePart): Vector3
	local sample = samples[part]
	local current = part.AssemblyLinearVelocity
	if sample and (os.clock() - sample.at) <= VELOCITY_SAMPLE_TTL then
		-- Whichever is larger: the pre-impact sample, or the current value if
		-- the object is still accelerating.
		if sample.velocity.Magnitude > current.Magnitude then
			return sample.velocity
		end
	end
	return current
end

local function damageFor(speed: number): number
	if speed < MagnetConfig.ImpactMinSpeed then
		return 0
	end
	local raw = (speed - MagnetConfig.ImpactMinSpeed) * MagnetConfig.ImpactDamagePerSpeed
	return math.min(raw, MagnetConfig.ImpactMaxDamage)
end

local function characterOf(part: BasePart): (Player?, Humanoid?)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			return player, model:FindFirstChildOfClass("Humanoid")
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function onTouched(mover: BasePart, other: BasePart)
	if not mover.Parent or not other.Parent then
		return
	end
	if not MagneticRegistry.IsThrown(mover) then
		return
	end

	local thrower = MagneticRegistry.Thrower(mover)

	local moverVelocity = recordedVelocity(mover)
	local otherVelocity = if other.Anchored then Vector3.zero else recordedVelocity(other)
	local closingSpeed = (moverVelocity - otherVelocity).Magnitude

	local damage = damageFor(closingSpeed)
	if damage <= 0 then
		return
	end

	local heavy = damage >= MagnetConfig.ImpactMaxDamage * HEAVY_IMPACT_SHARE
	local contact = (mover.Position + other.Position) / 2

	-- Enemy hit by a thrown object (including another enemy).
	if EnemyService.IsEnemy(other) then
		if MagneticRegistry.TryConsumeDamageWindow(mover, other) then
			EnemyService.Damage(other, damage, thrower)
			SoundKit.PlayAt(if heavy then "ImpactHeavy" else "ImpactLight", contact)
			announceImpact("Impact", contact, damage, other.Color)
		end
		return
	end

	local victimPlayer, victimHumanoid = characterOf(other)
	if victimHumanoid then
		-- You cannot hurt yourself with your own throw; magnet traversal
		-- constantly puts objects near the thrower.
		if victimPlayer ~= thrower and MagneticRegistry.TryConsumeDamageWindow(mover, other) then
			victimHumanoid:TakeDamage(damage)
			SoundKit.PlayAt("PlayerHurt", contact)
			announceImpact("PlayerHurt", contact, damage)
		end
		return
	end

	-- Static geometry. If the thing that hit it was itself an enemy, this is
	-- the "slam it into a wall" kill.
	if EnemyService.IsEnemy(mover) and MagneticRegistry.TryConsumeDamageWindow(mover, other) then
		EnemyService.Damage(mover, damage, thrower)
		SoundKit.PlayAt(if heavy then "ImpactHeavy" else "ImpactLight", contact)
		announceImpact("Impact", contact, damage, mover.Color)
		return
	end

	-- A thrown crate hitting scenery still deserves a thud, just no damage
	-- event — this is most of what the player hears while learning to aim.
	if MagneticRegistry.TryConsumeDamageWindow(mover, other) then
		SoundKit.PlayAt(if heavy then "ImpactHeavy" else "ImpactLight", contact)
		announceImpact("Impact", contact, damage * 0.5, mover.Color)
	end
end

local function watch(instance: Instance)
	if not instance:IsA("BasePart") or connections[instance] then
		return
	end
	connections[instance] = instance.Touched:Connect(function(other)
		local ok, err = pcall(onTouched, instance, other)
		if not ok and GameConfig.Debug.MagnetResolution then
			warn(`[CombatService] impact handler error: {err}`)
		end
	end)
end

local function unwatch(instance: Instance)
	local connection = connections[instance :: BasePart]
	if connection then
		connection:Disconnect()
		connections[instance :: BasePart] = nil
	end
	samples[instance :: BasePart] = nil
end

function CombatService.Start()
	for _, instance in CollectionService:GetTagged(GameConfig.Tags.Magnetic) do
		watch(instance)
	end
	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.Magnetic):Connect(watch)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.Magnetic):Connect(unwatch)

	-- Sample velocities of in-flight objects every frame. Only thrown parts are
	-- tracked, so this stays proportional to what is actually moving.
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for part in connections do
			if part.Parent and MagneticRegistry.IsThrown(part) then
				samples[part] = { velocity = part.AssemblyLinearVelocity, at = now }
			end
		end
	end)
end

return CombatService
