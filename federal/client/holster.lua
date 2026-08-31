-- The holster.
--
-- Pressing the holster key (default Z, rebindable under FiveM keybinds) rests
-- the member's hand on their holster - the stance an officer takes before a
-- situation turns. It only engages when a configured sidearm is actually in
-- their inventory, verified server-side: an empty holster gets no theatre.
--
-- Drawing one of those sidearms plays a draw-from-the-hip animation with the
-- trigger disabled until the weapon is actually up, and putting it away plays
-- the re-holster. Both are cosmetic layers over the inventory's own equip -
-- nothing here grants or removes weapons.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State

local Holster = {}
Federal.Holster = Holster

local CLIPSET = 'move_m@intimidation@cop@unarmed'
local DICT = 'reaction@intimidation@1h'

local stance = false
local animating = false
local verified, verifiedAt = false, 0

local function config()
    return (Config.Federal or {}).holster or {}
end

local sidearms = nil
local function isSidearm(weaponHash)
    if not sidearms then
        sidearms = {}
        for _, name in ipairs(config().weapons or {}) do
            sidearms[GetHashKey(name:upper())] = true
        end
    end
    return sidearms[weaponHash] == true
end

function Holster.StanceActive()
    return stance
end

local function setStance(enabled)
    local ped = PlayerPedId()
    if enabled then
        RequestAnimSet(CLIPSET)
        local deadline = GetGameTimer() + 2000
        while not HasAnimSetLoaded(CLIPSET) and GetGameTimer() < deadline do Wait(10) end
        if not HasAnimSetLoaded(CLIPSET) then return end
        SetPedMovementClipset(ped, CLIPSET, 0.35)
    else
        ResetPedMovementClipset(ped, 0.35)
    end
    stance = enabled
end

-- The draw/holster flourish: upper-body animation with the trigger dead
-- until the motion completes, so the gun comes up like it left a holster
-- instead of teleporting into the hand.
local function playTransition(clip, duration)
    if animating then return end
    animating = true

    CreateThread(function()
        RequestAnimDict(DICT)
        local deadline = GetGameTimer() + 1500
        while not HasAnimDictLoaded(DICT) and GetGameTimer() < deadline do Wait(10) end

        local ped = PlayerPedId()
        if HasAnimDictLoaded(DICT) then
            TaskPlayAnim(ped, DICT, clip, 8.0, -8.0, duration, 48, 0, false, false, false)
        end

        local until_ = GetGameTimer() + duration
        while GetGameTimer() < until_ do
            DisablePlayerFiring(PlayerId(), true)
            DisableControlAction(0, 25, true) -- aim
            Wait(0)
        end
        StopAnimTask(ped, DICT, clip, 1.0)
        animating = false
    end)
end

-- The key ------------------------------------------------------------------

RegisterCommand('fedholster', function()
    if config().enabled == false then return end
    if not State.Membership() or not State.OnDuty() then return end
    if animating then return end

    if stance then
        setStance(false)
        return
    end

    -- Only with a sidearm actually in the holster; cached briefly so tapping
    -- the key is not a callback per press.
    if verified and (GetGameTimer() - verifiedAt) < 10000 then
        setStance(true)
        return
    end

    Bridge.TriggerCallback(Federal.Net('holster:check'), function(ok)
        verified, verifiedAt = ok == true, GetGameTimer()
        if verified then
            setStance(true)
        else
            Bridge.Notify('Your holster is empty.', 'error')
        end
    end)
end, false)

RegisterKeyMapping('fedholster', 'Federal: rest hand on holster', 'keyboard',
    (Config.Federal and Config.Federal.holster and Config.Federal.holster.defaultKey) or 'Z')

-- Draw and re-holster ------------------------------------------------------

CreateThread(function()
    local UNARMED = GetHashKey('WEAPON_UNARMED')
    local previous = UNARMED

    while true do
        Wait(150)
        if config().enabled ~= false and State.Membership() then
            local ped = PlayerPedId()
            local current = GetSelectedPedWeapon(ped)
            if current ~= previous then
                if previous == UNARMED and isSidearm(current) then
                    -- Out of the holster: the hand leaves the hip with the gun.
                    if stance then setStance(false) end
                    playTransition('intro', 1300)
                elseif isSidearm(previous) and (current == UNARMED or not isSidearm(current)) then
                    playTransition('outro', 1300)
                end
                previous = current
            end
        else
            previous = GetSelectedPedWeapon(PlayerPedId())
        end
    end
end)

-- Never leave the stance clipset behind when the resource stops.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and stance then
        ResetPedMovementClipset(PlayerPedId(), 0.0)
    end
end)

return Holster
