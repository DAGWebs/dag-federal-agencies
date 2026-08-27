-- Suspect behaviour.
--
-- The first version of this spawned a ped, called
-- SetBlockingOfNonTemporaryEvents(true) and SetPedFleeAttributes(0), then
-- waited for someone to press E on it. That is a prop, not a suspect.
--
-- A suspect here decides on approach whether to run, and if cornered whether
-- to fight or give up. They surrender when outnumbered or at gunpoint, and
-- detaining one only works once they are actually subdued -- which is what
-- makes the arrest the end of something rather than a keypress.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Suspects = {}
Federal.Suspects = Suspects

-- ped -> behaviour state. Only the scene host runs this.
local tracked = {}

local function settings()
    return ((Config.Federal or {}).callouts or {}).suspect or {}
end

local function chance(value, fallback)
    local roll = tonumber(value)
    if roll == nil then roll = fallback or 0 end
    return math.random() < roll
end

function Suspects.Tracked()
    return tracked
end

function Suspects.State(ped)
    return tracked[ped]
end

function Suspects.Forget(ped)
    tracked[ped] = nil
end

function Suspects.Clear()
    tracked = {}
end

-- Decides a suspect's disposition once, at spawn, so their behaviour is
-- consistent for the whole callout rather than rerolled every frame.
function Suspects.Roll()
    local config = settings()
    local armed = chance(config.armedChance, 0.2)
    return {
        flees = chance(config.fleeChance, 0.55),
        fights = chance(config.fightChance, 0.25),
        armed = armed,
        weapon = armed and Suspects.Weapon() or nil
    }
end

function Suspects.Weapon()
    local weapons = settings().weapons
    if type(weapons) ~= 'table' or #weapons == 0 then return 'WEAPON_PISTOL' end
    return weapons[math.random(#weapons)]
end

-- Registers a spawned ped as a suspect and applies its disposition. Note the
-- deliberate absence of SetBlockingOfNonTemporaryEvents: the suspect is meant
-- to react to the world.
function Suspects.Attach(ped, calloutId, disposition)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    disposition = disposition or Suspects.Roll()
    local config = settings()

    SetPedAccuracy(ped, math.floor(tonumber(config.accuracy) or 25))
    SetPedArmour(ped, math.floor(tonumber(config.armour) or 0))
    SetPedFleeAttributes(ped, 0, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedSeeingRange(ped, 40.0)
    SetPedHearingRange(ped, 40.0)

    if disposition.armed and disposition.weapon then
        GiveWeaponToPed(ped, GetHashKey(disposition.weapon), 60, false, false)
        -- Holstered until they decide to fight: an NPC who spawns aiming makes
        -- the scene a shootout before anyone has said a word.
        SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
    end

    tracked[ped] = {
        ped = ped,
        calloutId = calloutId,
        disposition = disposition,
        stage = 'idle',
        origin = GetEntityCoords(ped),
        subdued = false
    }
    return tracked[ped]
end

-- Surrender conditions ------------------------------------------------------------

local function officersNear(coords, range)
    local count = 0
    for _, player in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(player)
        if DoesEntityExist(ped) and #(coords - GetEntityCoords(ped)) <= range then
            count = count + 1
        end
    end
    return count
end

Suspects.OfficersNear = officersNear

-- At gunpoint at close range, or outnumbered, a suspect gives up. Without this
-- every callout ends in a foot chase or a shooting.
function Suspects.ShouldSurrender(state)
    local config = settings()
    local coords = GetEntityCoords(state.ped)
    local range = tonumber(config.surrenderRange) or 12.0

    if officersNear(coords, range) >= (tonumber(config.surrenderUnits) or 2) then return true end

    local player = PlayerPedId()
    if IsPlayerFreeAiming(PlayerId()) and #(coords - GetEntityCoords(player)) <= 8.0 then return true end

    return false
end

function Suspects.Surrender(state)
    if state.stage == 'surrendered' then return end
    state.stage = 'surrendered'
    state.subdued = true

    ClearPedTasks(state.ped)
    SetPedKeepTask(state.ped, true)
    TaskHandsUp(state.ped, -1, 0, -1, false)
    Bridge.Notify('The suspect gives up.', 'success')
end

function Suspects.Subdue(state)
    state.subdued = true
    state.stage = 'detained'
    ClearPedTasks(state.ped)
    TaskStartScenarioInPlace(state.ped, 'WORLD_HUMAN_PRISONER_CROUCH', 0, true)
end

-- Behaviour loop ---------------------------------------------------------------------

local function nearestOfficer(coords)
    local best, bestDistance
    for _, player in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(player)
        if DoesEntityExist(ped) then
            local distance = #(coords - GetEntityCoords(ped))
            if not bestDistance or distance < bestDistance then best, bestDistance = ped, distance end
        end
    end
    return best, bestDistance
end

Suspects.NearestOfficer = nearestOfficer

-- One tick of one suspect. Split out so the decision logic is testable without
-- the surrounding thread.
function Suspects.Tick(state)
    if not state or not DoesEntityExist(state.ped) then return 'gone' end
    if state.subdued then return state.stage end

    if IsPedDeadOrDying(state.ped, true) then
        state.stage = 'down'
        state.subdued = true
        return 'down'
    end

    local coords = GetEntityCoords(state.ped)
    local officer, distance = nearestOfficer(coords)
    if not officer or not distance then return state.stage end

    -- Nobody close enough to react to yet.
    if distance > 30.0 and state.stage == 'idle' then return 'idle' end

    if Suspects.ShouldSurrender(state) then
        Suspects.Surrender(state)
        return 'surrendered'
    end

    local config = settings()

    if state.stage == 'idle' then
        if state.disposition.flees and distance <= 18.0 then
            state.stage = 'fleeing'
            ClearPedTasks(state.ped)
            TaskSmartFleePed(state.ped, officer, tonumber(config.fleeDistance) or 220.0, -1, false, false)
            Bridge.Notify('The suspect is running.', 'inform')
        elseif state.disposition.fights and distance <= 6.0 then
            state.stage = 'fighting'
            if state.disposition.armed and state.disposition.weapon then
                SetCurrentPedWeapon(state.ped, GetHashKey(state.disposition.weapon), true)
            end
            ClearPedTasks(state.ped)
            TaskCombatPed(state.ped, officer, 0, 16)
            Bridge.Notify('The suspect is resisting.', 'error')
        end
        return state.stage
    end

    -- A suspect who has run far enough gives up rather than sprinting to the
    -- edge of the map forever.
    if state.stage == 'fleeing' then
        if #(coords - state.origin) >= (tonumber(config.fleeDistance) or 220.0) then
            Suspects.Surrender(state)
            return 'surrendered'
        end
        -- Cornered: they stopped moving and an officer is on top of them.
        if distance <= 2.5 and GetEntitySpeed(state.ped) < 0.5 then
            if state.disposition.fights then
                state.stage = 'fighting'
                ClearPedTasks(state.ped)
                TaskCombatPed(state.ped, officer, 0, 16)
            else
                Suspects.Surrender(state)
                return 'surrendered'
            end
        end
    end

    return state.stage
end

-- Only the scene host runs this, and only while it has suspects to run.
CreateThread(function()
    while true do
        local sleep = 1000
        for ped, state in pairs(tracked) do
            sleep = 300
            local result = Suspects.Tick(state)
            if result == 'gone' then tracked[ped] = nil end
        end
        Wait(sleep)
    end
end)

return Suspects
