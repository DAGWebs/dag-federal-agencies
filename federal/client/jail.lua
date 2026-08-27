-- Being inside.
--
-- The leash is the important part: an inmate who clips through a wall is
-- teleported back rather than punished, because most escapes from a GTA
-- interior are a physics accident rather than a plan.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Jail = {}
Federal.Jail = Jail

local state = { inside = false, cells = nil, leash = 120.0, remaining = 0 }

local function id(name)
    return Federal.Menus.Id('jail:' .. name)
end

function Jail.Inside()
    return state.inside
end

function Jail.Remaining()
    return state.remaining
end

local function teleport(point)
    if type(point) ~= 'table' then return end
    local ped = PlayerPedId()
    SetEntityCoords(ped, point.x, point.y, point.z, false, false, false, false)
    ClearPedTasksImmediately(ped)
end

function Jail.Enter(payload)
    if type(payload) ~= 'table' then return end

    state.inside = true
    state.cells = payload.cells
    state.leash = tonumber(payload.leash) or 120.0
    state.remaining = tonumber(payload.remaining) or 0

    teleport(payload.cells)
    Bridge.Notify(('You are in custody. %s'):format(Jail.Clock()), 'error', 10000)
end

function Jail.Leave(payload)
    state.inside = false
    state.remaining = 0
    teleport(type(payload) == 'table' and payload.release or state.cells)
end

-- Formats the remaining time the way an inmate wants to read it.
function Jail.Clock(seconds)
    local remaining = math.max(0, math.floor(tonumber(seconds) or state.remaining))
    local minutes = math.floor(remaining / 60)
    if minutes >= 1 then
        return ('%d minute%s remaining'):format(minutes, minutes == 1 and '' or 's')
    end
    return ('%d second%s remaining'):format(remaining, remaining == 1 and '' or 's')
end

function Jail.Menu()
    Bridge.TriggerCallback(Federal.Net('jail:status'), function(status)
        if not status then
            return Bridge.Notify('You are not in custody.', 'inform')
        end

        local options = {
            { title = status.name or 'Inmate', description = status.caseNumber, disabled = true },
            { title = Jail.Clock(status.remaining), badge = ('%d months'):format(status.months or 0), disabled = true },
            { title = 'Work', header = true },
            {
                title = 'Take a work detail',
                description = 'Time off your sentence',
                icon = 'wrench',
                onSelect = Jail.Labour
            }
        }
        Federal.CAD.Show(id('menu'), 'Custody', nil, options)
    end)
end

function Jail.Labour()
    local timings = (Config.Federal or {}).timings or {}
    if not Federal.Progress.Run({
        label = 'Working',
        duration = timings.writeReport or 4000,
        animation = 'deploy'
    }) then return end

    Bridge.TriggerCallback(Federal.Net('jail:labour'), function(result, err)
        if not result then return Bridge.Notify(err or 'No work available.', 'error') end
        if result.released then return Bridge.Notify('Time served. You are released.', 'success') end

        state.remaining = result.remaining
        Bridge.Notify(('%d seconds off. %s'):format(result.reduced or 0, Jail.Clock(result.remaining)), 'success')
    end)
end

-- The roster, for officers rather than inmates.
function Jail.Roster()
    Bridge.TriggerCallback(Federal.Net('jail:roster'), function(list)
        local options = {}
        for _, inmate in ipairs(list or {}) do
            options[#options + 1] = {
                title = inmate.name,
                description = ('%s | %d month(s)'):format(inmate.caseNumber or 'no case', inmate.months or 0),
                icon = 'lock',
                badge = Jail.Clock(inmate.remaining),
                badgeTone = inmate.online and 'accent' or nil,
                onSelect = function()
                    if not Federal.State.Can('actions.arrest') then return end
                    DAG.Menu.Confirm(('Release %s?'):format(inmate.name), 'They walk free immediately.',
                        function(confirmed)
                            if not confirmed then return end
                            TriggerServerEvent(Federal.Net('jail:release'), inmate.identifier)
                            SetTimeout(250, function() Jail.Roster() end)
                        end)
                end
            }
        end

        if #(list or {}) == 0 then
            options[1] = { title = 'Nobody in custody', disabled = true }
        end
        Federal.CAD.Show(id('roster'), 'Custody roster', ('%d inmate(s)'):format(#(list or {})), options)
    end)
end

RegisterNetEvent(Federal.Net('jailed'), function(payload)
    Jail.Enter(payload)
end)

RegisterNetEvent(Federal.Net('released'), function(payload)
    Jail.Leave(payload)
end)

-- The leash. Only runs while inside, and only checks twice a second.
CreateThread(function()
    while true do
        local sleep = 2000
        if state.inside and state.cells then
            sleep = 500
            local ped = PlayerPedId()
            local distance = #(GetEntityCoords(ped) - vector3(state.cells.x, state.cells.y, state.cells.z))
            if distance > state.leash then
                teleport(state.cells)
                Bridge.Notify('You are not going anywhere.', 'error')
            end
            if state.remaining > 0 then state.remaining = state.remaining - 0.5 end
        end
        Wait(sleep)
    end
end)

return Jail
