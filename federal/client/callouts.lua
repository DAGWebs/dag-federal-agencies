-- The callout scene on the client.
--
-- One assigned officer is the scene HOST: their machine spawns the suspect,
-- the witnesses and the evidence markers, so exactly one client owns them.
-- Everyone else assigned sees the blip and the objective list and interacts
-- with entities the host created.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Callouts = {}
Federal.Callouts = Callouts

local known = {}
local scene = { calloutId = nil, peds = {}, blip = nil, evidence = {}, interactions = {} }

local function id(name)
    return Federal.Menus.Id('callout:' .. name)
end

-- Scene teardown -----------------------------------------------------------------

local function clearScene()
    for _, ped in ipairs(scene.peds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    for _, interaction in ipairs(scene.interactions) do DAG.Interactions.Remove(interaction) end
    if scene.blip and DoesBlipExist(scene.blip) then RemoveBlip(scene.blip) end

    scene = { calloutId = nil, peds = {}, blip = nil, evidence = {}, interactions = {} }
end

Callouts.ClearScene = clearScene

-- Scene construction --------------------------------------------------------------

local function spawnPed(model, coords, heading)
    local hash = GetHashKey(model)
    RequestModel(hash)

    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then return nil end

    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, heading or 0.0, true, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedDiesWhenInjured(ped, false)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)

    scene.peds[#scene.peds + 1] = ped
    return ped
end

Callouts.SpawnPed = spawnPed

-- Scatters evidence points around the scene. They are client-side markers; the
-- record they create is filed on the server when one is worked.
local function placeEvidence(callout)
    local spread = (callout.evidence and callout.evidence.radius) or 15.0
    local kinds = (callout.evidence and callout.evidence.kinds) or { 'print' }
    local wanted = 0

    for _, stage in ipairs(callout.stages or {}) do
        if stage.kind == 'evidence' then wanted = math.max(wanted, stage.count or 1) end
    end
    -- One spare, so a player who misses a marker is not stuck.
    wanted = wanted + 1

    for index = 1, wanted do
        local angle = (index / wanted) * math.pi * 2
        local point = {
            x = callout.location.x + (math.cos(angle) * spread * 0.6),
            y = callout.location.y + (math.sin(angle) * spread * 0.6),
            z = callout.location.z
        }
        local kind = kinds[((index - 1) % #kinds) + 1]
        local markerId = ('federal:callout:%s:evidence:%d'):format(callout.id, index)

        DAG.Interactions.Register({
            id = markerId,
            coords = vector3(point.x, point.y, point.z),
            distance = 2.0,
            marker = 21,
            label = 'Press ~INPUT_CONTEXT~ to collect evidence',
            canInteract = function() return State.Can('actions.evidence') end,
            onSelect = function()
                local timings = (Config.Federal or {}).timings or {}
                -- Lifting a print off a bad surface can fail; the marker is
                -- only removed once the work is actually done, so a fumble
                -- leaves the evidence there to try again.
                if not Federal.Progress.Attempt({
                    label = 'Collecting evidence',
                    duration = timings.collectEvidence or 5000,
                    animation = 'collect',
                    skill = kind == 'print' and { 'easy', 'medium' } or nil,
                    failure = 'You disturbed it. Try again.'
                }) then return end

                DAG.Interactions.Remove(markerId)
                Bridge.TriggerCallback(Federal.Net('cad:collect'), function(record)
                    if record then
                        Bridge.Notify(('Collected %s (%s).'):format(record.label, record.number), 'success')
                    end
                end, {
                    kind = kind,
                    calloutId = callout.id,
                    location = point,
                    subject = callout.suspect and callout.suspect.identifier or nil
                })
            end
        })

        scene.interactions[#scene.interactions + 1] = markerId
    end
end

-- Builds the scene. Only the host does this.
local function buildScene(callout)
    clearScene()
    scene.calloutId = callout.id

    scene.blip = Federal.Zones.AddBlip(callout.location, callout.label, callout.blip)
    if scene.blip then SetBlipRoute(scene.blip, true) end

    -- A real player suspect is already in the world; only an NPC needs one.
    if callout.suspect and callout.suspect.kind == 'npc' then
        local ped = spawnPed(callout.suspect.model, {
            x = callout.location.x + 2.0,
            y = callout.location.y + 1.0,
            z = callout.location.z
        }, 0.0)

        if ped then
            local suspectId = ('federal:callout:%s:suspect'):format(callout.id)
            DAG.Interactions.Register({
                id = suspectId,
                coords = vector3(callout.location.x + 2.0, callout.location.y + 1.0, callout.location.z),
                distance = 2.5,
                label = 'Press ~INPUT_CONTEXT~ to detain the suspect',
                canInteract = function() return State.Can('actions.detain') end,
                onSelect = function()
                    Callouts.Report(callout.id, 'arrest')
                    if DoesEntityExist(ped) then
                        ClearPedTasks(ped)
                        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_PRISONER_CROUCH', 0, true)
                    end
                end
            })
            scene.interactions[#scene.interactions + 1] = suspectId
        end
    end

    local witnesses = (callout.witnesses and callout.witnesses.count) or 0
    for index = 1, witnesses do
        local models = (callout.witnesses.models and #callout.witnesses.models > 0)
            and callout.witnesses.models or { 'a_m_y_business_01' }
        local point = {
            x = callout.location.x - 2.0 - index,
            y = callout.location.y + 2.0,
            z = callout.location.z
        }
        local ped = spawnPed(models[((index - 1) % #models) + 1], point, 180.0)

        if ped then
            local witnessId = ('federal:callout:%s:witness:%d'):format(callout.id, index)
            DAG.Interactions.Register({
                id = witnessId,
                coords = vector3(point.x, point.y, point.z),
                distance = 2.5,
                label = 'Press ~INPUT_CONTEXT~ to interview',
                onSelect = function() Callouts.Report(callout.id, 'interview') end
            })
            scene.interactions[#scene.interactions + 1] = witnessId
        end
    end

    placeEvidence(callout)
end

-- Progress ---------------------------------------------------------------------------

function Callouts.Report(calloutId, stageId)
    Bridge.TriggerCallback(Federal.Net('callout:progress'), function(result)
        if result then Callouts.Track(result) end
    end, calloutId, stageId)
end

function Callouts.Track(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = callout

    if callout.host == GetPlayerServerId(PlayerId()) and scene.calloutId ~= callout.id then
        buildScene(callout)
    end

    local stage = callout.stages and callout.stages[callout.stage]
    if stage then Bridge.Notify(('Objective: %s'):format(stage.label), 'inform') end
end

-- Menus ---------------------------------------------------------------------------------

function Callouts.Menu()
    Bridge.TriggerCallback(Federal.Net('callouts'), function(list)
        local options = {}
        for _, callout in ipairs(list or {}) do
            known[callout.id] = callout
            local stage = callout.stages and callout.stages[callout.stage]
            options[#options + 1] = {
                title = callout.label,
                description = stage and stage.label or 'Complete',
                icon = 'info',
                badge = callout.number,
                badgeTone = callout.priority >= 3 and 'danger' or 'accent',
                onSelect = function() Callouts.Detail(callout.id) end
            }
        end
        Federal.CAD.Show(id('list'), 'Active callouts', ('%d running'):format(#(list or {})), options)
    end)
end

function Callouts.Detail(calloutId)
    local callout = known[calloutId]
    if not callout then return Bridge.Notify('That callout is no longer active.', 'error') end

    local me = GetPlayerServerId(PlayerId())
    local assigned = false
    for _, source in ipairs(callout.assigned or {}) do
        if source == me then assigned = true end
    end

    local options = {
        { title = callout.number, description = callout.description, disabled = true },
        { title = 'Objectives', header = true }
    }

    for index, stage in ipairs(callout.stages or {}) do
        local done = index < callout.stage
        options[#options + 1] = {
            title = stage.label,
            icon = done and 'check' or 'chevron',
            badge = done and 'Done' or (index == callout.stage and 'Current' or 'Pending'),
            badgeTone = done and 'success' or (index == callout.stage and 'accent' or nil),
            disabled = true
        }
    end

    options[#options + 1] = { title = 'Actions', header = true }
    if not assigned then
        options[#options + 1] = {
            title = 'Attach to this callout',
            icon = 'check',
            onSelect = function()
                Bridge.TriggerCallback(Federal.Net('callout:attach'), function(result, err)
                    if not result then return Bridge.Notify(err or 'Refused.', 'error') end
                    Callouts.Track(result)
                end, calloutId)
            end
        }
    else
        local stage = callout.stages and callout.stages[callout.stage]
        if stage then
            options[#options + 1] = {
                title = ('Report: %s'):format(stage.label),
                description = 'The server checks this before accepting it',
                icon = 'check',
                onSelect = function() Callouts.Report(calloutId, stage.id) end
            }
        end
        options[#options + 1] = {
            title = 'Detach',
            icon = 'close',
            onSelect = function()
                TriggerServerEvent(Federal.Net('callout:detach'), calloutId)
                if scene.calloutId == calloutId then clearScene() end
            end
        }
    end

    if State.Can('callout.manage') then
        options[#options + 1] = {
            title = 'Cancel the callout',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm('Cancel this callout?', callout.number, function(confirmed)
                    if confirmed then TriggerServerEvent(Federal.Net('callout:cancel'), calloutId) end
                end)
            end
        }
    end

    Federal.CAD.Show(id('detail'), callout.label, callout.number, options)
end

-- Events -----------------------------------------------------------------------------------

RegisterNetEvent(Federal.Net('callout:dispatch'), function(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = callout
    Bridge.Notify(('%s: %s'):format(callout.number, callout.label), 'inform', 8000)
    PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)
end)

RegisterNetEvent(Federal.Net('callout:update'), function(callout)
    Callouts.Track(callout)
end)

RegisterNetEvent(Federal.Net('callout:closed'), function(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = nil
    if scene.calloutId == callout.id then clearScene() end
    Bridge.Notify(('%s closed.'):format(callout.number), 'success')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearScene() end
end)

return Callouts
