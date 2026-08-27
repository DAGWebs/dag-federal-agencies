-- Client entry point for the federal resource.
--
-- Loaded last of the federal client files so every module it wires together
-- already exists. Nothing here calls a native at load time: the first context
-- request waits for the framework to report a player.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework

-- Opens the menu the player is standing in front of, or the main menu.
RegisterCommand(Bridge.namespace .. ':fed', function()
    Federal.Menus.Open()
end, false)

RegisterCommand(Bridge.namespace .. ':fedcad', function()
    Federal.MDT.Open()
end, false)

RegisterCommand(Bridge.namespace .. ':fedcourt', function()
    Federal.Court.Docket()
end, false)

-- Open to everybody: restricting who may report a crime is a strange thing
-- for a server to want, and it is the only source of work nobody planned.
RegisterCommand(Bridge.namespace .. ':report', function()
    Federal.Reports.Call()
end, false)

-- Bindable: nobody opens a menu during the thing a panic button is for.
RegisterCommand(Bridge.namespace .. ':panic', function()
    Federal.Units.Toggle()
end, false)

-- For inmates: time remaining and the work detail that shortens it.
RegisterCommand(Bridge.namespace .. ':custody', function()
    Federal.Jail.Menu()
end, false)

CreateThread(function()
    -- The framework needs a moment to report a player before the first context
    -- read means anything.
    Bridge.AwaitReady(15000)
    Wait(1000)

    Federal.State.Refresh()
    Federal.Court.Refresh()
end)

-- A late-arriving context (a promotion, an editor write) rebuilds the world
-- through the state listener registered in zones.lua.
Federal.State.OnChange(function(context)
    Bridge.Debug('federal context: %d agenc(ies), on duty: %s',
        #(context.agencies or {}), tostring(context.membership and context.membership.onDuty))
end)

return true
