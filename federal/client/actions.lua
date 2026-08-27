-- LEO actions on the client: picking a target, playing the animations, and
-- holding the restraint state the server told this player they are under.
--
-- Nothing here decides anything. The client picks who you are pointing at and
-- asks; the server re-reads both positions and the officer's rank before it
-- agrees. The restraint loop below runs on the player being restrained, from
-- state the server pushed to them.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local Actions = {}
Federal.Actions = Actions

local restraint = { cuffed = false, arrested = false }
local escortedBy = nil

local CUFF_DICT = 'mp_arresting'
local CUFF_ANIM = 'idle'

-- Targeting ------------------------------------------------------------------

-- The closest other player within `limit`, as a server id. Returns nil rather
-- than a best guess when nobody is close enough.
function Actions.NearestPlayer(limit)
    local player = PlayerPedId()
    local origin = GetEntityCoords(player)
    local best, bestDistance

    for _, other in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(other)
        if ped ~= player and DoesEntityExist(ped) then
            local distance = #(origin - GetEntityCoords(ped))
            if distance <= (limit or 4.0) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = other, distance
            end
        end
    end

    if not best then return nil end
    return GetPlayerServerId(best), bestDistance
end

-- The vehicle the player is looking at or standing beside, as a network id so
-- the server can resolve the same entity.
function Actions.NearestVehicle(limit)
    local ped = PlayerPedId()
    local origin = GetEntityCoords(ped)

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        vehicle = GetClosestVehicle(origin.x, origin.y, origin.z, limit or 6.0, 0, 71)
    end
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    return NetworkGetNetworkIdFromEntity(vehicle), vehicle
end

local function requireTarget()
    local target = Actions.NearestPlayer((Config.Federal or {}).actionDistance or 4.0)
    if not target then
        Bridge.Notify('Nobody is close enough.', 'error')
        return nil
    end
    return target
end

Actions.RequireTarget = requireTarget

-- Restraint ---------------------------------------------------------------------

local function playCuffAnim()
    RequestAnimDict(CUFF_DICT)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(CUFF_DICT) and GetGameTimer() < deadline do Wait(10) end
    if not HasAnimDictLoaded(CUFF_DICT) then return end
    TaskPlayAnim(PlayerPedId(), CUFF_DICT, CUFF_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)
end

function Actions.Restrained()
    return restraint.cuffed == true
end

local function applyRestraint(state)
    restraint = type(state) == 'table' and state or { cuffed = false }
    local ped = PlayerPedId()

    if restraint.cuffed then
        SetEnableHandcuffs(ped, true)
        playCuffAnim()
    else
        SetEnableHandcuffs(ped, false)
        ClearPedTasks(ped)
        escortedBy = nil
    end
end

RegisterNetEvent(Federal.Net('restraint'), function(state)
    applyRestraint(state)
end)

RegisterNetEvent(Federal.Net('escort'), function(officer)
    escortedBy = officer
    local ped = PlayerPedId()
    if not officer then return DetachEntity(ped, true, false) end

    local escortPed = GetPlayerPed(GetPlayerFromServerId(officer))
    if escortPed and escortPed ~= 0 then
        AttachEntityToEntity(ped, escortPed, 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    end
end)

RegisterNetEvent(Federal.Net('seat'), function(netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    DetachEntity(PlayerPedId(), true, false)
    -- Rear seats first: a detainee does not ride shotgun.
    for seat = 1, 3 do
        if IsVehicleSeatFree(vehicle, seat) then
            return SetPedIntoVehicle(PlayerPedId(), vehicle, seat)
        end
    end
end)

-- A restrained player keeps their hands cuffed and cannot drive, shoot or
-- punch their way out. The loop only runs while they are actually restrained.
CreateThread(function()
    while true do
        local sleep = 500
        if restraint.cuffed then
            sleep = 0
            local ped = PlayerPedId()
            DisableControlAction(0, 24, true)   -- attack
            DisableControlAction(0, 25, true)   -- aim
            DisableControlAction(0, 45, true)   -- reload
            DisableControlAction(0, 22, true)   -- jump
            DisableControlAction(0, 21, true)   -- sprint
            DisableControlAction(0, 75, true)   -- exit vehicle
            if not IsEntityPlayingAnim(ped, CUFF_DICT, CUFF_ANIM, 3) and not escortedBy then
                playCuffAnim()
            end
        end
        Wait(sleep)
    end
end)

-- Action helpers ------------------------------------------------------------------

function Actions.Cuff()
    local target = requireTarget()
    if target then TriggerServerEvent(Federal.Net('action:cuff'), target) end
end

function Actions.Escort()
    local target = requireTarget()
    if target then TriggerServerEvent(Federal.Net('action:escort'), target) end
end

function Actions.Seat()
    local target = requireTarget()
    if not target then return end

    local netId = Actions.NearestVehicle(8.0)
    if not netId then return Bridge.Notify('No vehicle nearby.', 'error') end
    TriggerServerEvent(Federal.Net('action:seat'), target, netId)
end

function Actions.Release()
    local target = requireTarget()
    if target then TriggerServerEvent(Federal.Net('action:release'), target) end
end

-- Renders a search report as a menu so the officer can read what was found
-- rather than watching notifications scroll past.
function Actions.ShowSearch(report)
    local options = {}
    if #report.found == 0 then
        options[1] = { title = 'Nothing found', description = 'The subject is carrying no listed contraband.', disabled = true }
    else
        options[#options + 1] = { title = 'Contraband', header = true }
        for _, entry in ipairs(report.found) do
            local seized = false
            for _, taken in ipairs(report.seized) do
                if taken.item == entry.item then seized = true end
            end
            options[#options + 1] = {
                title = entry.item,
                description = seized and 'Seized and logged as evidence' or 'Left with the subject',
                badge = ('x%d'):format(entry.count),
                badgeTone = seized and 'danger' or 'accent',
                disabled = true
            }
        end
    end

    DAG.Menu.Register({
        id = Federal.Menus.Id('search'),
        title = ('Search: %s'):format(report.name or 'subject'),
        subtitle = #report.evidence > 0 and ('%d item(s) filed as evidence'):format(#report.evidence) or nil,
        options = options
    })
    DAG.Menu.Open(Federal.Menus.Id('search'))
end

function Actions.Search()
    local target = requireTarget()
    if not target then return end

    Bridge.TriggerCallback(Federal.Net('action:search'), function(report, err)
        if not report then return Bridge.Notify(err or 'The search was refused.', 'error') end
        Actions.ShowSearch(report)
    end, target)
end

function Actions.SearchVehicle()
    local netId = Actions.NearestVehicle(8.0)
    if not netId then return Bridge.Notify('No vehicle nearby.', 'error') end

    Bridge.TriggerCallback(Federal.Net('action:searchVehicle'), function(result, err)
        if not result then return Bridge.Notify(err or 'The search was refused.', 'error') end

        local options = {}
        if #result.occupants == 0 then
            options[1] = { title = 'Vehicle is empty', description = 'Nobody was inside to search.', disabled = true }
        end
        for _, report in ipairs(result.occupants) do
            options[#options + 1] = {
                title = report.name or 'Occupant',
                description = #report.found > 0 and ('%d contraband item(s)'):format(#report.found) or 'Nothing found',
                badge = #report.found > 0 and 'HIT' or 'CLEAR',
                badgeTone = #report.found > 0 and 'danger' or 'success',
                onSelect = function() Actions.ShowSearch(report) end
            }
        end

        DAG.Menu.Register({
            id = Federal.Menus.Id('vehicleSearch'),
            title = 'Vehicle search',
            subtitle = 'Occupants searched',
            options = options
        })
        DAG.Menu.Open(Federal.Menus.Id('vehicleSearch'))
    end, netId)
end

function Actions.Identify()
    local target = requireTarget()
    if not target then return end

    Bridge.TriggerCallback(Federal.Net('action:identify'), function(result, err)
        if not result then return Bridge.Notify(err or 'Identification was refused.', 'error') end

        local options = {
            { title = result.name or 'Unknown', description = result.identifier, disabled = true }
        }
        if result.warrant then
            options[#options + 1] = {
                title = 'ACTIVE WARRANT',
                description = result.warrant.reason,
                badge = result.warrant.number,
                badgeTone = 'danger',
                disabled = true
            }
        end
        if result.record then
            options[#options + 1] = {
                title = 'Prior arrests',
                badge = tostring(#(result.record.arrests or {})),
                disabled = true
            }
            options[#options + 1] = {
                title = 'Fingerprints on file',
                badge = result.record.printed and 'Yes' or 'No',
                badgeTone = result.record.printed and 'success' or nil,
                disabled = true
            }
        else
            options[#options + 1] = { title = 'No record on file', disabled = true }
        end

        DAG.Menu.Register({
            id = Federal.Menus.Id('identify'),
            title = 'Identification',
            options = options
        })
        DAG.Menu.Open(Federal.Menus.Id('identify'))
    end, target)
end

function Actions.Fingerprint()
    local target = requireTarget()
    if not target then return end

    Bridge.TriggerCallback(Federal.Net('action:fingerprint'), function(result, err)
        Bridge.Notify(result and ('%s is now on file.'):format(result.name) or (err or 'Refused.'),
            result and 'success' or 'error')
    end, target)
end

function Actions.Swab()
    local target = requireTarget()
    if not target then return end

    Bridge.TriggerCallback(Federal.Net('action:swab'), function(record, err)
        Bridge.Notify(record and ('Swab logged as %s.'):format(record.number) or (err or 'Refused.'),
            record and 'success' or 'error')
    end, target)
end

function Actions.Arrest()
    local target = requireTarget()
    if not target then return end

    DAG.Menu.Input('Charges', {
        { name = 'charges', label = 'Charges (comma separated)', required = true },
        { name = 'incident', label = 'Attach to incident id (optional)' }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[1] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end
        if #charges == 0 then return Bridge.Notify('No charges entered.', 'error') end

        Bridge.TriggerCallback(Federal.Net('action:arrest'), function(booking, err)
            if not booking then return Bridge.Notify(err or 'The arrest was refused.', 'error') end
            local suffix = booking.caseNumber and (' Case %s filed.'):format(booking.caseNumber) or ''
            Bridge.Notify(('%s booked.%s'):format(booking.name or 'Subject', suffix), 'success')
        end, target, { charges = charges, incidentId = values.incident or values[2] })
    end)
end

function Actions.Fine()
    local target = requireTarget()
    if not target then return end

    DAG.Menu.Input('Issue a fine', {
        { name = 'amount', label = 'Amount', type = 'number', required = true },
        { name = 'reason', label = 'Reason', required = true }
    }, function(values)
        if not values then return end
        TriggerServerEvent(Federal.Net('action:fine'), target,
            tonumber(values.amount or values[1]), values.reason or values[2])
    end)
end

function Actions.SetStatus(status)
    if not Const.UnitStatus[status] then return end
    TriggerServerEvent(Federal.Net('status'), status)
end

-- The action list, filtered to what this player's rank allows. Used by the
-- field menu and by the callout scene menu.
function Actions.Options()
    local options = {}
    local function add(permission, option)
        if State.Can(permission) then options[#options + 1] = option end
    end

    add('actions.detain', { title = 'Cuff / uncuff', icon = 'lock', onSelect = Actions.Cuff })
    add('actions.detain', { title = 'Escort / release hold', icon = 'user', onSelect = Actions.Escort })
    add('actions.detain', { title = 'Seat in vehicle', icon = 'car', onSelect = Actions.Seat })
    add('actions.search', { title = 'Search suspect', icon = 'box', onSelect = Actions.Search })
    add('actions.search', { title = 'Search vehicle', icon = 'car', onSelect = Actions.SearchVehicle })
    add('actions.search', { title = 'Identify subject', icon = 'info', onSelect = Actions.Identify })
    add('actions.evidence', { title = 'Fingerprint subject', icon = 'user', onSelect = Actions.Fingerprint })
    add('actions.evidence', { title = 'Take DNA swab', icon = 'box', onSelect = Actions.Swab })
    add('actions.arrest', { title = 'Book arrest', icon = 'lock', badgeTone = 'danger', onSelect = Actions.Arrest })
    add('actions.arrest', { title = 'Issue fine', icon = 'cash', onSelect = Actions.Fine })
    add('actions.arrest', { title = 'Release subject', icon = 'check', onSelect = Actions.Release })

    return options
end

return Actions
