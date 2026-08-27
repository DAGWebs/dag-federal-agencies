-- Deploying and picking up field equipment.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Equipment = {}
Federal.Equipment = Equipment

-- netId -> entity, for the objects this client created.
local spawned = {}

local function id(name)
    return Federal.Menus.Id('equipment:' .. name)
end

local function settings()
    return (Config.Federal or {}).equipment or {}
end

function Equipment.Spawned()
    return spawned
end

-- Places the object in front of the officer, on the ground, facing the way
-- they are facing.
function Equipment.Create(definition)
    local hash = GetHashKey(definition.model)
    RequestModel(hash)

    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then
        Bridge.Notify(('The model %s is not on this server.'):format(definition.model), 'error')
        return nil
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local offset = tonumber(definition.offset) or 1.5

    local forward = {
        x = coords.x + (math.sin(-math.rad(heading)) * offset * -1.0),
        y = coords.y + (math.cos(-math.rad(heading)) * offset),
        z = coords.z
    }

    local object = CreateObject(hash, forward.x, forward.y, forward.z - 1.0, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityHeading(object, heading)
    PlaceObjectOnGroundProperly(object)
    FreezeEntityPosition(object, true)

    local netId = NetworkGetNetworkIdFromEntity(object)
    spawned[netId] = object
    return netId, object
end

function Equipment.Remove(netId)
    local object = spawned[netId] or NetworkGetEntityFromNetworkId(netId)
    if object and object ~= 0 and DoesEntityExist(object) then DeleteEntity(object) end
    spawned[netId] = nil
end

function Equipment.Menu()
    Bridge.TriggerCallback(Federal.Net('equipment:list'), function(payload)
        payload = payload or { available = {}, deployed = {} }
        local options = { { title = 'Deploy', header = true } }

        for _, entry in ipairs(payload.available) do
            options[#options + 1] = {
                title = entry.label,
                description = entry.locked and entry.lockedReason or entry.model,
                icon = 'box',
                badge = entry.item or 'Issued',
                badgeTone = entry.locked and 'danger' or 'accent',
                disabled = entry.locked,
                onSelect = function() Equipment.Deploy(entry) end
            }
        end

        options[#options + 1] = { title = 'Deployed', header = true }
        for _, record in ipairs(payload.deployed) do
            options[#options + 1] = {
                title = record.label,
                description = ('Placed by %s'):format(record.by or 'unknown'),
                icon = 'wrench',
                badge = 'Pick up',
                onSelect = function() Equipment.Retrieve(record) end
            }
        end
        if #payload.deployed == 0 then
            options[#options + 1] = { title = 'Nothing deployed', disabled = true }
        end

        if Federal.State.Can('callout.manage') and #payload.deployed > 0 then
            options[#options + 1] = {
                title = 'Clear everything',
                icon = 'close',
                badgeTone = 'danger',
                onSelect = function()
                    DAG.Menu.Confirm('Clear all deployed equipment?', 'Everything the agency has out.',
                        function(confirmed)
                            if confirmed then TriggerServerEvent(Federal.Net('equipment:clearAll')) end
                        end)
                end
            }
        end

        Federal.CAD.Show(id('menu'), 'Field equipment', nil, options)
    end)
end

function Equipment.Deploy(entry)
    local timings = (Config.Federal or {}).timings or {}
    if not Federal.Progress.Run({
        label = ('Deploying %s'):format(entry.label),
        duration = timings.deploy or 2000,
        animation = 'deploy'
    }) then return end

    local netId, object = Equipment.Create(entry)
    if not netId then return end

    Bridge.TriggerCallback(Federal.Net('equipment:deploy'), function(record, err)
        if record then return Bridge.Notify(('Deployed %s.'):format(record.label), 'success') end

        -- The server refused it, so the object must not stay in the world.
        if object and DoesEntityExist(object) then DeleteEntity(object) end
        spawned[netId] = nil
        Bridge.Notify(err or 'That was refused.', 'error')
    end, entry.id, netId)
end

function Equipment.Retrieve(record)
    -- Picking something up means going to it.
    local ped = PlayerPedId()
    local object = NetworkGetEntityFromNetworkId(record.netId)
    if object and object ~= 0 and DoesEntityExist(object) then
        local distance = #(GetEntityCoords(ped) - GetEntityCoords(object))
        if distance > (tonumber(settings().pickupDistance) or 2.5) + 2.0 then
            return Bridge.Notify('You are not close enough to that.', 'error')
        end
    end

    local timings = (Config.Federal or {}).timings or {}
    if not Federal.Progress.Run({
        label = ('Picking up %s'):format(record.label),
        duration = timings.deploy or 2000,
        animation = 'deploy'
    }) then return end

    Bridge.TriggerCallback(Federal.Net('equipment:retrieve'), function(result, err)
        if not result then return Bridge.Notify(err or 'That was refused.', 'error') end
        Equipment.Remove(record.netId)
        Bridge.Notify(('Picked up %s.'):format(result.label), 'success')
    end, record.id)
end

RegisterNetEvent(Federal.Net('equipment:clear'), function(netIds)
    for _, netId in ipairs(type(netIds) == 'table' and netIds or {}) do Equipment.Remove(netId) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for netId in pairs(spawned) do Equipment.Remove(netId) end
end)

return Equipment
