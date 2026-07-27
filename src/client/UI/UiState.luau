--!nonstrict
--[[
	UiState.luau — who owns the screen right now

	Two panels used to be able to sit on top of each other, each with its own
	full-screen scrim, and both of them left the magnet armed underneath. Opening
	the shop mid-run and clicking a swatch would fire Pull at whatever happened to
	be behind the button.

	This module is the single owner of that state. A panel registers a close
	function once and then asks to open through here, which means:

	  • **One panel at a time.** Opening the shop closes the board, so there is
	    never a scrim stacked on a scrim.

	  • **The magnet is not live while a menu is.** MagnetController is suppressed
	    for as long as anything is open, and told to let go of whatever it was
	    holding on the way in — otherwise a player who opens the board mid-grapple
	    keeps flying while reading a leaderboard.

	  • **The cursor is free.** A player in first person has MouseBehavior locked
	    to the centre of the screen and physically cannot click a button. Roblox
	    unlocks the mouse while a visible GuiButton has `Modal` set, so every
	    panel's scrim is registered here and flagged for exactly as long as the
	    panel is up.
]]

local UiState = {}

type Panel = {
	name: string,
	close: () -> (),
	scrim: GuiButton?,
}

local panels: { [string]: Panel } = {}
local openPanel: string? = nil

--- Injected by the bootstrap. Kept as a hook rather than a require so this
--- module stays a leaf that any panel can pull in without a cycle.
local onSuppressionChanged: (boolean) -> () = function() end

function UiState.SetSuppressionHandler(handler: (boolean) -> ())
	onSuppressionChanged = handler
end

--- @param scrim the panel's full-screen backdrop button, flagged Modal while open
function UiState.Register(name: string, close: () -> (), scrim: GuiButton?)
	panels[name] = { name = name, close = close, scrim = scrim }
end

function UiState.IsAnyOpen(): boolean
	return openPanel ~= nil
end

function UiState.OpenPanel(): string?
	return openPanel
end

local function applyScrim(name: string?, modal: boolean)
	local panel = name and panels[name]
	local scrim = panel and panel.scrim
	if scrim then
		scrim.Modal = modal
	end
end

--- Called by a panel that has just made itself visible. Closes whatever else was
--- up first, so the caller never has to know about its siblings.
function UiState.NotifyOpened(name: string)
	if openPanel == name then
		applyScrim(name, true)
		return
	end

	local previous = openPanel
	if previous then
		applyScrim(previous, false)
		local panel = panels[previous]
		-- Set the new owner first: the old panel's close handler calls back into
		-- NotifyClosed, and it must not clear a state it no longer owns.
		openPanel = name
		if panel then
			panel.close()
		end
	end

	openPanel = name
	applyScrim(name, true)
	onSuppressionChanged(true)
end

function UiState.NotifyClosed(name: string)
	applyScrim(name, false)
	if openPanel ~= name then
		return
	end
	openPanel = nil
	onSuppressionChanged(false)
end

--- Closes whatever is open. Used when something else needs the screen — a
--- teleport, a death — so the player is never left reading a menu over a
--- gameplay event.
function UiState.CloseAll()
	local current = openPanel
	if not current then
		return
	end
	local panel = panels[current]
	if panel then
		panel.close()
	end
	-- Belt and braces: if a close handler forgot to report back, do not leave the
	-- magnet suppressed forever.
	if openPanel == current then
		applyScrim(current, false)
		openPanel = nil
		onSuppressionChanged(false)
	end
end

return UiState
