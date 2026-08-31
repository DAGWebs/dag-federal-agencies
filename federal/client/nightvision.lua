-- Night vision goggles.
--
-- A member wearing an NVG helmet presses the toggle key and the helmet prop
-- swaps to its lenses-down drawable while night vision switches on; pressing
-- again flips the lenses back up and the world returns to normal. Which
-- helmet drawables pair up lives in Config.Federal.nightVision, because prop
-- ids differ between game builds and clothing packs.
--
-- Purely visual + screen effect: no items are consumed and nothing is
-- granted. Wearing a helmet that is in the pair list is the whole gate.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State

local NightVision = {}
Federal.NightVision = NightVision

local active = false

local function config()
    return (Config.Federal or {}).nightVision or {}
end

local function pairsFor(ped)
    local helmets = config().helmets or {}
    return (IsPedMale(ped) and helmets.male or helmets.female) or {}
end

function NightVision.Active()
    return active
end

local function goggleState(ped)
    local drawable = GetPedPropIndex(ped, 0)
    if drawable < 0 then return nil end
    for _, pair in ipairs(pairsFor(ped)) do
        if drawable == pair.up then return 'up', pair end
        if drawable == pair.down then return 'down', pair end
    end
    return nil
end

local function setNight(enabled)
    active = enabled
    SetNightvision(enabled)
end

function NightVision.Toggle()
    if config().enabled == false then return end
    if not State.Membership() or not State.OnDuty() then return end

    local ped = PlayerPedId()
    local state, pair = goggleState(ped)
    if not state then
        return Bridge.Notify('You are not wearing night vision goggles.', 'error')
    end

    local texture = GetPedPropTextureIndex(ped, 0)
    if state == 'up' then
        SetPedPropIndex(ped, 0, pair.down, texture, true)
        setNight(true)
    else
        SetPedPropIndex(ped, 0, pair.up, texture, true)
        setNight(false)
    end
end

RegisterCommand('fednvg', function()
    NightVision.Toggle()
end, false)

RegisterKeyMapping('fednvg', 'Federal: toggle night vision goggles', 'keyboard',
    (Config.Federal and Config.Federal.nightVision and Config.Federal.nightVision.defaultKey) or 'K')

-- If the helmet comes off (locker room, uniform change, death) while the
-- lenses are down, the effect follows the goggles off the head.
CreateThread(function()
    while true do
        Wait(active and 500 or 1500)
        if active then
            local state = goggleState(PlayerPedId())
            if state ~= 'down' then setNight(false) end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and active then SetNightvision(false) end
end)

return NightVision
