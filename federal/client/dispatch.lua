-- The built-in dispatch alert: a notification, a blip and a sound, used when
-- no external dispatch resource is handling it.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Dispatch = {}
Federal.Dispatch = Dispatch

local blips = {}

-- Alerts fade rather than pile up: a map covered in every call of the shift is
-- no more useful than a map with none.
local LIFETIME = 180000

function Dispatch.Blips()
    return blips
end

function Dispatch.Clear()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    blips = {}
end

function Dispatch.Show(alert)
    if type(alert) ~= 'table' then return nil end

    if alert.message or alert.title then
        Bridge.Notify(('%s%s'):format(
            alert.code and (alert.code .. ': ') or '',
            alert.message or alert.title), 'inform', 9000)
    end
    PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)

    if type(alert.coords) ~= 'table' then return nil end

    local blip = Federal.Zones.AddBlip(alert.coords, alert.title or 'Dispatch', {
        sprite = alert.sprite or 480,
        color = alert.colour or 5,
        scale = (alert.priority or 2) >= 3 and 1.0 or 0.85,
        shortRange = false
    })
    if not blip then return nil end

    blips[#blips + 1] = blip
    SetTimeout(LIFETIME, function()
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        for index, existing in ipairs(blips) do
            if existing == blip then table.remove(blips, index) break end
        end
    end)
    return blip
end

RegisterNetEvent(Federal.Net('dispatch'), function(alert)
    Dispatch.Show(alert)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Dispatch.Clear() end
end)

return Dispatch
