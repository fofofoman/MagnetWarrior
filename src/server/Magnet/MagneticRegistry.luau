--!nonstrict
--[[
	MagneticRegistry.luau

	Tracks every part the magnet is allowed to touch, and — critically — takes
	network ownership of them away from clients.

	By default Roblox hands simulation of an unanchored part to whichever client
	is nearest, which would mean an exploiter's machine decides where a pushed
	crate ends up and how fast it hits an enemy. `SetNetworkOwner(nil)` forces the
	server to simulate them, so the impulse the server applies is the motion
	everyone sees. This is the foundation the whole server-authority story rests
	on; without it the rest of the anti-cheat work is decoration.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MagnetConfig = require(Shared.Config.MagnetConfig)
local Signal = require(Shared.Util.Signal)

local MagneticRegistry = {}

--- Fired with (part, player, action, impulseMagnitude) every time the magnet
--- moves something. Systems that need to react to *the force the server
--- applied* — rather than to whatever the physics engine did with it
--- afterwards — listen here. BossService uses it so its damage window does not
--- depend on how far a constraint happens to stretch.
MagneticRegistry.Impulsed = Signal.new()

export type MagneticInfo = {
	part: BasePart,
	isSurface: boolean, -- anchored wall you can cling to
	lastImpulseAt: number,
	lastImpulseBy: Player?,
	lastDamageAt: { [Instance]: number },
}

local infoByPart: { [BasePart]: MagneticInfo } = {}
local connections: { RBXScriptConnection } = {}

--- Taking server ownership fails for anchored parts and for anything welded
--- into a player's character; both are expected, so failure is not an error.
local function claimServerOwnership(part: BasePart)
	if part.Anchored then
		return
	end

	local model = part:FindFirstAncestorOfClass("Model")
	if model and Players:GetPlayerFromCharacter(model) then
		return
	end

	local ok, err = pcall(function()
		part:SetNetworkOwner(nil)
	end)
	if not ok and GameConfig.Debug.MagnetResolution then
		warn(`[MagneticRegistry] could not claim ownership of {part:GetFullName()}: {err}`)
	end
end

local function register(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end

	local existing = infoByPart[instance]
	if existing then
		existing.isSurface = CollectionService:HasTag(instance, GameConfig.Tags.MagneticSurface)
		return
	end

	infoByPart[instance] = {
		part = instance,
		isSurface = CollectionService:HasTag(instance, GameConfig.Tags.MagneticSurface),
		lastImpulseAt = 0,
		lastImpulseBy = nil,
		-- Weak-keyed: this accumulates one entry per distinct thing the part has
		-- ever touched. A crate in a busy arena meets a new enemy every wave, and
		-- those enemies are destroyed — a strong table would pin every corpse it
		-- ever hit for as long as the crate exists.
		lastDamageAt = setmetatable({}, { __mode = "k" }) :: any,
	}

	claimServerOwnership(instance)
end

local function unregister(instance: Instance)
	if instance:IsA("BasePart") then
		infoByPart[instance] = nil
	end
end

function MagneticRegistry.Start()
	for _, tag in { GameConfig.Tags.Magnetic, GameConfig.Tags.MagneticSurface } do
		for _, instance in CollectionService:GetTagged(tag) do
			register(instance)
		end
		table.insert(connections, CollectionService:GetInstanceAddedSignal(tag):Connect(register))
		table.insert(connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
			-- A part may hold both tags; only drop it once neither remains.
			if
				not CollectionService:HasTag(instance, GameConfig.Tags.Magnetic)
				and not CollectionService:HasTag(instance, GameConfig.Tags.MagneticSurface)
			then
				unregister(instance)
			end
		end))
	end
end

function MagneticRegistry.Stop()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(infoByPart)
end

function MagneticRegistry.Get(part: BasePart?): MagneticInfo?
	if not part then
		return nil
	end
	return infoByPart[part]
end

function MagneticRegistry.IsMagnetic(part: BasePart?): boolean
	return part ~= nil and infoByPart[part] ~= nil
end

--- Iterating a table of a few hundred parts every action is cheap compared to a
--- spatial query, and stages are built to a fixed size. Revisit with an Octree
--- if a stage ever holds thousands of magnetic parts.
function MagneticRegistry.All(): { [BasePart]: MagneticInfo }
	return infoByPart
end

--- An assembly is immovable if it is anchored or simply too heavy for the
--- magnet — in which case the force reflects onto the player, which is how
--- traversal works.
function MagneticRegistry.IsImmovable(part: BasePart): boolean
	if part.Anchored then
		return true
	end

	local root = part.AssemblyRootPart
	if root and root.Anchored then
		return true
	end

	return part.AssemblyMass > MagnetConfig.ImmovableMassThreshold
end

--- Records who threw this part and when, so CombatService can attribute impact
--- damage and ignore objects that are merely rolling around.
function MagneticRegistry.MarkImpulsed(part: BasePart, player: Player, action: string?, magnitude: number?)
	local info = infoByPart[part]
	if not info then
		return
	end
	info.lastImpulseAt = os.clock()
	info.lastImpulseBy = player

	MagneticRegistry.Impulsed:Fire(part, player, action or "Push", magnitude or 0)
end

--- True while the part still counts as "thrown".
function MagneticRegistry.IsThrown(part: BasePart): boolean
	local info = infoByPart[part]
	if not info then
		return false
	end
	return (os.clock() - info.lastImpulseAt) <= MagnetConfig.ImpactActiveWindow
end

function MagneticRegistry.Thrower(part: BasePart): Player?
	local info = infoByPart[part]
	if not info or not MagneticRegistry.IsThrown(part) then
		return nil
	end
	return info.lastImpulseBy
end

--- Per (object, victim) damage cooldown so one slam is one hit, not twelve.
function MagneticRegistry.TryConsumeDamageWindow(part: BasePart, victim: Instance): boolean
	local info = infoByPart[part]
	if not info then
		return false
	end

	local now = os.clock()
	local last = info.lastDamageAt[victim]
	if last and (now - last) < MagnetConfig.ImpactCooldown then
		return false
	end

	info.lastDamageAt[victim] = now
	return true
end

return MagneticRegistry
