-- Client-side cache of what the server said this player is and may do.
--
-- Nothing here is authority. The permission map exists so a menu can hide a
-- row the player cannot use; the server re-checks every action regardless. A
-- client that lies to itself about `Can` gets a refusal, not a privilege.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = {}
Federal.State = State

local context = { agencies = {}, permissions = {}, membership = nil, enabled = true }
local listeners = {}
local roster = {}

function State.Context()
    return context
end

function State.Agencies()
    return context.agencies or {}
end

function State.Agency(id)
    for _, agency in ipairs(context.agencies or {}) do
        if agency.id == id then return agency end
    end
    return nil
end

function State.Membership()
    return context.membership
end

-- The player's own agency, or nil when they are not in one.
function State.Mine()
    local membership = context.membership
    return membership and State.Agency(membership.agencyId) or nil
end

function State.Can(permission)
    if context.admin == true then return true end
    return (context.permissions or {})[permission] == true
end

function State.OnDuty()
    return context.membership ~= nil and context.membership.onDuty == true
end

function State.Grade()
    return context.membership and context.membership.grade or 0
end

function State.Roster()
    return roster
end

-- Anything that needs to redraw when the registry or the player's rank
-- changes registers here: blips, interactions and any open menu.
function State.OnChange(handler)
    if type(handler) == 'function' then listeners[#listeners + 1] = handler end
end

local function broadcast()
    for _, handler in ipairs(listeners) do
        -- Contained so one bad listener cannot stop the others, but printed
        -- rather than debug-logged: the listeners are what draw the blips and
        -- register the interactions, so a silent failure here leaves a player
        -- with an empty map and no way to tell why.
        local ok, err = pcall(handler, context)
        if not ok then Bridge.Print('federal state listener errored: %s', tostring(err)) end
    end
end

function State.Apply(payload)
    if type(payload) ~= 'table' then return end
    context = payload
    context.agencies = context.agencies or {}
    context.permissions = context.permissions or {}
    broadcast()
end

function State.Refresh()
    Bridge.TriggerCallback(Federal.Net('context'), function(payload)
        if payload then State.Apply(payload) end
    end)
end

RegisterNetEvent(Federal.Net('context'), function(payload)
    State.Apply(payload)
end)

RegisterNetEvent(Federal.Net('roster'), function(units)
    roster = type(units) == 'table' and units or {}
end)

-- The framework can hand the player a different job at any time, and the
-- rank that job carries decides everything below it.
Bridge.On('playerLoaded', function() State.Refresh() end)
Bridge.On('jobUpdated', function() State.Refresh() end)

return State
