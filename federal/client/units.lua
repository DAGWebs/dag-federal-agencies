-- Seeing your colleagues.
--
-- The roster was a list in a menu, which is not the same as knowing where
-- anybody is. Officers who cannot see each other cannot back each other up,
-- and the panic status existed in the constants table doing nothing at all.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local Units = {}
Federal.Units = Units

-- source -> blip. Reused between pushes rather than recreated, so a unit's
-- blip does not flicker every interval.
local blips = {}
local panics = {}

local STATUS_COLOUR = {
    available = 2,   -- green
    enroute   = 3,   -- blue
    onscene   = 5,   -- yellow
    busy      = 17,  -- orange
    panic     = 1    -- red
}

Units.StatusColour = STATUS_COLOUR

function Units.Blips()
    return blips
end

function Units.Clear()
    for source, blip in pairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        blips[source] = nil
    end
    for source in pairs(panics) do Units.ClearPanic(source) end
end

local function label(unit)
    return ('%s %s'):format(unit.callsign or '?', unit.name or '')
end

-- Draws or moves one unit's blip.
function Units.Draw(unit)
    if type(unit) ~= 'table' or type(unit.coords) ~= 'table' or not unit.source then return nil end

    local blip = blips[unit.source]
    if not blip or not DoesBlipExist(blip) then
        blip = AddBlipForCoord(unit.coords.x, unit.coords.y, unit.coords.z)
        SetBlipAsShortRange(blip, false)
        blips[unit.source] = blip
    else
        SetBlipCoords(blip, unit.coords.x, unit.coords.y, unit.coords.z)
    end

    SetBlipSprite(blip, 1)
    SetBlipScale(blip, unit.panic and 1.0 or 0.75)
    SetBlipColour(blip, STATUS_COLOUR[unit.status] or 2)
    SetBlipFlashes(blip, unit.panic == true)
    ShowHeadingIndicatorOnBlip(blip, true)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label(unit))
    EndTextCommandSetBlipName(blip)
    return blip
end

-- Replaces the whole set from one push. Units that dropped out of the payload
-- have gone off duty or out of view, and their blips go with them.
function Units.Apply(list)
    local seen = {}
    for _, unit in ipairs(type(list) == 'table' and list or {}) do
        Units.Draw(unit)
        seen[unit.source] = true
    end

    for source, blip in pairs(blips) do
        if not seen[source] then
            if DoesBlipExist(blip) then RemoveBlip(blip) end
            blips[source] = nil
        end
    end
end

-- Panic ---------------------------------------------------------------------------

function Units.Panic(payload)
    if type(payload) ~= 'table' or not payload.source then return end

    local settings = ((Config.Federal or {}).units or {}).panic or {}
    Bridge.Notify(('PANIC: %s %s needs assistance'):format(payload.callsign or '', payload.name or ''),
        'error', 12000)

    if settings.sound ~= false then
        PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)
    end

    if type(payload.coords) == 'table' then
        local blip = AddBlipForCoord(payload.coords.x, payload.coords.y, payload.coords.z)
        SetBlipSprite(blip, 161)
        SetBlipColour(blip, 1)
        SetBlipScale(blip, 1.2)
        SetBlipFlashes(blip, true)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(('PANIC - %s'):format(payload.callsign or 'unit'))
        EndTextCommandSetBlipName(blip)

        if settings.route ~= false then SetBlipRoute(blip, true) end
        panics[payload.source] = blip
    end
end

function Units.ClearPanic(source)
    local blip = panics[source]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    panics[source] = nil
end

function Units.Panicking()
    return panics
end

-- Sends the officer's own panic. Toggling it off is deliberate: it is the one
-- status that does not clear itself.
function Units.Toggle()
    if not State.OnDuty() then
        return Bridge.Notify('You are not on duty.', 'error')
    end

    local membership = State.Membership()
    local active = membership and membership.unit and membership.unit.status == 'panic'
    TriggerServerEvent(Federal.Net('panic'), not active)
end

RegisterNetEvent(Federal.Net('units'), function(list)
    if ((Config.Federal or {}).units or {}).enabled == false then return end
    Units.Apply(list)
end)

RegisterNetEvent(Federal.Net('panic'), function(payload)
    Units.Panic(payload)
end)

RegisterNetEvent(Federal.Net('panic:clear'), function(source)
    Units.ClearPanic(source)
end)

-- Off duty there is nothing to draw, and leaving the blips up would show a
-- civilian where every federal unit is.
State.OnChange(function()
    if not State.OnDuty() then Units.Clear() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Units.Clear() end
end)

-- Status list, with panic separated out because it behaves differently.
function Units.StatusOptions()
    local options = {}
    for _, status in ipairs(Const.UnitStatusOrder) do
        if status ~= 'panic' then
            local detail = Const.UnitStatus[status]
            options[#options + 1] = {
                title = detail.label,
                icon = 'user',
                badgeTone = detail.tone,
                onSelect = function() Federal.Actions.SetStatus(status) end
            }
        end
    end

    options[#options + 1] = { title = 'Emergency', header = true }
    options[#options + 1] = {
        title = 'Panic button',
        description = 'Routes every unit to you until you clear it',
        icon = 'lock',
        badgeTone = 'danger',
        onSelect = Units.Toggle
    }
    return options
end

return Units
