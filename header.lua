--[[
	OpenDex
]]

local selection
local nodes = {}

cloneref = cloneref or function(ref)
	return ref
end

local oldgame = cloneref(game)
local game = cloneref(workspace.Parent)
