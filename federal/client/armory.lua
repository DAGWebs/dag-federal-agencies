-- Locker room, armory and motor pool menus.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Armory = {}
Federal.Armory = Armory

local function id(name)
    return Federal.Menus.Id('armory:' .. name)
end

-- Locker room ------------------------------------------------------------------

function Armory.Locker()
    local agency = State.Mine()
    if not agency then return end

    local grade = State.Grade()
    local options = {}

    for _, uniform in ipairs(agency.uniforms or {}) do
        local wearable = Federal.Uniforms.Wearable(uniform, grade)
        options[#options + 1] = {
            title = uniform.label,
            description = uniform.variant ~= 'any' and ('Fitted for %s'):format(uniform.variant) or nil,
            icon = 'user',
            badge = wearable and 'Issued' or 'Restricted',
            badgeTone = wearable and 'success' or 'danger',
            disabled = not wearable,
            onSelect = function() TriggerServerEvent(Federal.Net('uniform:wear'), uniform.id) end
        }
    end

    if #options == 0 then
        options[1] = {
            title = 'No uniforms configured',
            description = 'A boss can add one from the command office',
            disabled = true
        }
    end

    options[#options + 1] = { title = 'Civilian clothes', header = true }
    options[#options + 1] = {
        title = 'Go off duty and change back',
        icon = 'close',
        description = 'Clears the uniform by reloading your saved appearance',
        onSelect = function()
            -- Player appearance belongs to the framework or a skin resource,
            -- so this asks for it rather than inventing one.
            TriggerEvent(Federal.Net('restoreAppearance'))
            Bridge.Notify('Requested your civilian appearance.', 'inform')
        end
    }

    Federal.CAD.Show(id('locker'), 'Locker room', agency.label, options)
end

-- Armory ---------------------------------------------------------------------------

function Armory.Open()
    Bridge.TriggerCallback(Federal.Net('armory'), function(list)
        local options, category = {}, nil

        for _, entry in ipairs(list or {}) do
            if entry.category ~= category then
                category = entry.category
                options[#options + 1] = { title = category, header = true }
            end
            options[#options + 1] = {
                title = entry.label,
                description = entry.locked and entry.lockedReason or ('%s x%d'):format(entry.item, entry.count),
                icon = 'box',
                badge = entry.price > 0 and ('$%d'):format(entry.price) or 'Issued',
                badgeTone = entry.locked and 'danger' or 'accent',
                disabled = entry.locked,
                onSelect = function() TriggerServerEvent(Federal.Net('armory:draw'), entry.id) end
            }
        end

        Federal.CAD.Show(id('armory'), 'Armory', 'Draw issued equipment', options)
    end)
end

-- Motor pool -------------------------------------------------------------------------

local function spawnVehicle(model)
    local hash = GetHashKey(model)
    RequestModel(hash)

    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then
        return Bridge.Notify(('The model %s is not on this server.'):format(model), 'error')
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetModelAsNoLongerNeeded(hash)
    SetPedIntoVehicle(ped, vehicle, -1)
    SetVehicleNumberPlateText(vehicle, ('FED%03d'):format(math.random(0, 999)))
    Bridge.Notify('Vehicle drawn from the motor pool.', 'success')
end

RegisterNetEvent(Federal.Net('spawnVehicle'), function(model)
    if type(model) == 'string' then spawnVehicle(model) end
end)

function Armory.Garage()
    local agency = State.Mine()
    if not agency then return end

    local models = (Config.Federal or {}).vehicles or {}
    local options = {}
    for _, entry in ipairs(models[agency.id] or models.default or {}) do
        options[#options + 1] = {
            title = entry.label or entry.model,
            description = entry.model,
            icon = 'car',
            onSelect = function() TriggerServerEvent(Federal.Net('armory:vehicle'), entry.model) end
        }
    end

    if #options == 0 then
        options[1] = {
            title = 'No vehicles configured',
            description = 'Add them under Config.Federal.vehicles',
            disabled = true
        }
    end

    Federal.CAD.Show(id('garage'), 'Motor pool', agency.label, options)
end

return Armory
