-- Client side of agency door locks.
--
-- Every client registers every door with the game's door system, so a locked
-- gate is physically locked for everyone, member or not. What members get on
-- top is the prompt to toggle the doors their grade controls; the toggle
-- itself is authorized and distance-checked on the server.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State

local Doors = {}
Federal.DoorLocks = Doors

local doors = {} -- last synced list, every agency

-- Door system states: 0 = unlocked, 1 = locked. State 4 (FORCE_LOCKED) is a
-- per-frame force state that latches the door shut and does not cleanly
-- release when set back to 0 - which reads as "locks fine, never unlocks".
local DOOR_LOCKED = 1
local DOOR_UNLOCKED = 0

local function doorHash(door)
    return GetHashKey(('federal-door:%s:%s'):format(door.agency or '', door.id))
end

local function applyDoor(door)
    local hash = doorHash(door)
    if not IsDoorRegisteredWithSystem(hash) then
        AddDoorToSystem(hash, door.model, door.coords.x, door.coords.y, door.coords.z, false, false, false)
    end
    DoorSystemSetDoorState(hash, door.locked and DOOR_LOCKED or DOOR_UNLOCKED, false, true)
    -- A door that was mid-swing when it locked keeps its open ratio; snapping
    -- it shut on lock makes the state legible at a glance.
    if door.locked then
        DoorSystemSetOpenRatio(hash, 0.0, false, true)
    end
end

local synced = false

local function rebuild(list)
    doors = type(list) == 'table' and list or {}
    synced = true
    for _, door in ipairs(doors) do
        if type(door.coords) == 'table' and door.model then
            applyDoor(door)
        end
    end
end

RegisterNetEvent(Federal.Net('doors:sync'), function(list)
    rebuild(list)
end)

-- Initial pull, retried until it lands: the first attempt can race the
-- server's own boot, and a door list that never arrives would leave every
-- gate unlocked until the next edit happened to broadcast one.
CreateThread(function()
    for attempt = 1, 6 do
        Wait(attempt == 1 and 2500 or 5000)
        if synced then return end
        Bridge.TriggerCallback(Federal.Net('doors'), function(list)
            if list and not synced then rebuild(list) end
        end)
    end
end)

-- The prompt --------------------------------------------------------------------
--
-- A styled NUI chip instead of floating help text. It anchors to the door's
-- configured prompt point when one is set (from /fedconfig), otherwise to the
-- door object itself, and only shows for members whose grade controls the
-- door (and admins).

local function controllable(door)
    if State.Context().admin then return true end
    local membership = State.Membership()
    if not membership or membership.agencyId ~= door.agency then return false end
    return State.Grade() >= (door.minGrade or 0)
end

local function promptPoint(door)
    local point = door.prompt or door.coords
    return vector3(point.x, point.y, point.z)
end

local function promptReach(door)
    -- The configured radius decides how far the prompt reaches, whether it
    -- anchors to the door object or to an explicit prompt point.
    return door.radius or 4.0
end

CreateThread(function()
    local shown = nil
    local cooldownUntil = 0

    while true do
        local ped = PlayerPedId()
        local position = GetEntityCoords(ped)

        local best, bestDistance, anyClose = nil, nil, false
        for _, door in ipairs(doors) do
            if type(door.coords) == 'table' and controllable(door) then
                local point = promptPoint(door)
                local distance = #(position - point)
                if distance < 14.0 then anyClose = true end
                if distance <= promptReach(door) and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = door, distance
                end
            end
        end

        if best then
            local key = ('%s:%s:%s'):format(best.agency, best.id, tostring(best.locked))
            if shown ~= key then
                shown = key
                SendNUIMessage({
                    action = 'door:prompt',
                    show = true,
                    label = best.label,
                    locked = best.locked == true
                })
            end
            if GetGameTimer() >= cooldownUntil and IsControlJustReleased(0, 38) then
                cooldownUntil = GetGameTimer() + 900
                TriggerServerEvent(Federal.Net('door:toggle'), best.agency, best.id)
            end
            Wait(0)
        else
            if shown then
                shown = nil
                SendNUIMessage({ action = 'door:prompt', show = false })
            end
            -- No ground marker on approach; the prompt chip is the whole UI.
            Wait(anyClose and 150 or 500)
        end
    end
end)

-- Capture: a raycast from the gameplay camera to whatever door object the
-- player is aiming at. Returns the object's model and position, which is all
-- the door system needs.
function Doors.CaptureAim()
    local camCoord = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)

    local pitch = math.rad(camRot.x)
    local yaw = math.rad(camRot.z)
    local direction = vector3(-math.sin(yaw) * math.cos(pitch), math.cos(yaw) * math.cos(pitch), math.sin(pitch))
    local target = camCoord + direction * 12.0

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        camCoord.x, camCoord.y, camCoord.z, target.x, target.y, target.z,
        16, PlayerPedId(), 4)
    local _, hit, _, _, entity = GetShapeTestResult(handle)

    if hit ~= 1 or not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, 'aim at the door and try again'
    end
    if GetEntityType(entity) ~= 3 then
        return nil, 'that is not a door object'
    end

    local model = GetEntityModel(entity)
    local coords = GetEntityCoords(entity)

    -- The interaction radius scales with the door: a compound gate's origin
    -- can be metres from where a player stands at its middle.
    local min, max = GetModelDimensions(model)
    local radius = 4.0
    if min and max then
        local width = math.max(math.abs(max.x - min.x), math.abs(max.y - min.y))
        radius = math.min(math.max(width / 2.0 + 2.0, 2.5), 10.0)
    end

    return { model = model, coords = { x = coords.x, y = coords.y, z = coords.z }, radius = radius }
end

-- /feddoor round trip: the command asks this client to capture what it is
-- aiming at; the server authorizes the add.
RegisterNetEvent(Federal.Net('captureDoor'), function(agencyId, label, minGrade)
    local captured, message = Doors.CaptureAim()
    if not captured then return Bridge.Notify(message, 'error') end

    TriggerServerEvent(Federal.Net('door:add'), agencyId, {
        model = captured.model,
        coords = captured.coords,
        radius = captured.radius,
        label = label,
        minGrade = tonumber(minGrade) or 0
    })
end)

-- Unlock everything we registered when the resource stops, so a restart
-- never leaves a door permanently sealed.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, door in ipairs(doors) do
        local hash = doorHash(door)
        if IsDoorRegisteredWithSystem(hash) then
            DoorSystemSetDoorState(hash, DOOR_UNLOCKED, false, true)
            RemoveDoorFromSystem(hash)
        end
    end
end)

return Doors
